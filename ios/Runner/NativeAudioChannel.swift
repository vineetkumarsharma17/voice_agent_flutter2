import AVFoundation
import Flutter
import UIKit

private let kMethodChannel = "com.voiceagent/native_audio"
private let kEventChannel  = "com.voiceagent/native_audio_stream"

// ─────────────────────────────────────────────────────────────────────────────
//  NativeAudioChannel
//
//  Single owner of AVAudioSession + AVAudioEngine.
//  No Flutter plugin (record / just_audio / audio_session) touches the session.
//
//  Playback format : 22 050 Hz mono float32  (matches piper-TTS output)
//  Recording tap   : native hw rate, nil format → converted to 16 kHz PCM-16
// ─────────────────────────────────────────────────────────────────────────────
@objc class NativeAudioChannel: NSObject, FlutterStreamHandler {

    // ── Singleton ─────────────────────────────────────────────────────────
    @objc static let shared = NativeAudioChannel()
    private override init() {
        super.init()
        subscribeToAudioSessionNotifications()
    }

    // ── Flutter channels ──────────────────────────────────────────────────
    private var methodChannel: FlutterMethodChannel?
    private var eventChannel:  FlutterEventChannel?
    private var eventSink:     FlutterEventSink?

    // ── Audio engines ─────────────────────────────────────────────────────
    //  Two separate AVAudioEngine instances — one for playback, one for
    //  recording. This is the key architectural decision:
    //
    //  Single-engine approach (previous) caused:
    //   • startRecording had to stop the engine (topology change for tap)
    //     which killed any in-progress TTS playback → silence
    //   • stopRecording stopped the engine → TTS couldn't start until
    //     playWav restarted it, losing the first chunk
    //   • playerNode.isPlaying state was reset every time the engine stopped
    //
    //  Two-engine approach:
    //   • playbackEngine runs continuously once started; never stopped by KWS
    //   • recordEngine starts/stops independently for the mic tap
    //   • KWS and TTS can run truly simultaneously with no interference
    private let playbackEngine = AVAudioEngine()
    private let recordEngine   = AVAudioEngine()
    private let playerNode     = AVAudioPlayerNode()
    private var isRecording       = false
    private var playbackReady     = false
    private var recordEngineReady = false

    // Playback format — must match piper-lessac TTS WAV output
    private let playbackSampleRate: Double = 22050
    private let playbackChannels:   UInt32 = 1

    // Recording conversion target
    private let recordSampleRate:  Double         = 16000
    private let tapBufferSize: AVAudioFrameCount  = 4096

    // Lazy PCM-16 target format for the mic tap conversion
    private lazy var recordTargetFmt: AVAudioFormat? = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: recordSampleRate,
        channels: 1, interleaved: true)

    // ── Registration ──────────────────────────────────────────────────────
    func register(messenger: FlutterBinaryMessenger) {
        print("[NativeAudio] register()")
        methodChannel = FlutterMethodChannel(name: kMethodChannel,
                                             binaryMessenger: messenger)
        eventChannel  = FlutterEventChannel(name: kEventChannel,
                                            binaryMessenger: messenger)
        methodChannel?.setMethodCallHandler(handleMethod)
        eventChannel?.setStreamHandler(self)
    }

    // ── FlutterStreamHandler ───────────────────────────────────────────────
    func onListen(withArguments arguments: Any?,
                  eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        print("[NativeAudio] EventChannel onListen")
        eventSink = events
        return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        print("[NativeAudio] EventChannel onCancel")
        eventSink = nil
        return nil
    }

    // ── Method dispatch ────────────────────────────────────────────────────
    private func handleMethod(_ call: FlutterMethodCall,
                               result: @escaping FlutterResult) {
        print("[NativeAudio] method=\(call.method)")
        switch call.method {
        case "configure":         configure(result: result)
        case "startRecording":    startRecording(result: result)
        case "stopRecording":     stopRecording(result: result)
        case "stopPlayback":      stopPlayback(result: result)
        case "hasPermission":     hasPermission(result: result)
        case "requestPermission": requestPermission(result: result)
        case "setSpeaker":
            guard let args = call.arguments as? [String: Any],
                  let enabled = args["enabled"] as? Bool else {
                result(FlutterError(code: "BAD_ARGS",
                                    message: "setSpeaker requires {enabled:bool}",
                                    details: nil)); return
            }
            setSpeaker(enabled: enabled, result: result)
        case "playWav":
            guard let args  = call.arguments as? [String: Any],
                  let bytes = args["wavBytes"] as? FlutterStandardTypedData else {
                print("[NativeAudio] playWav: missing wavBytes")
                result(FlutterError(code: "BAD_ARGS",
                                    message: "playWav requires wavBytes",
                                    details: nil)); return
            }
            print("[NativeAudio] playWav: \(bytes.data.count)B")
            playWav(data: bytes.data, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    //  configure — activates session, wires + STARTS playbackEngine eagerly.
    //  playbackEngine stays running permanently so playWav can schedule
    //  buffers at any time without racing against engine start.
    // ─────────────────────────────────────────────────────────────────────
    private func configure(result: FlutterResult) {
        print("[NativeAudio] configure() playbackReady=\(playbackReady) running=\(playbackEngine.isRunning)")
        do {
            try activateSession()
            if !playbackReady { try setupPlaybackEngine() }
            // Start eagerly so playWav never has to start it mid-stream
            if !playbackEngine.isRunning {
                try playbackEngine.start()
                print("[NativeAudio] configure() playbackEngine started")
            }
            // NOTE: do NOT call playerNode.play() here — calling play() with
            // no buffers queued puts the node into a "starved" state where
            // subsequent scheduleBuffer calls are silently dropped.
            // playerNode.play() is called in playWav() right before the first
            // buffer is scheduled, which is the correct AVAudioPlayerNode pattern.
            print("[NativeAudio] configure() DONE")
            result(true)
        } catch {
            print("[NativeAudio] configure() FAILED: \(error)")
            result(FlutterError(code: "CONFIGURE_ERROR",
                                message: error.localizedDescription, details: "\(error)"))
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    //  activateSession  — shared helper
    //
    //  mode: .voiceChat  ← activates Apple's built-in Acoustic Echo
    //  Cancellation (AEC) / Voice Processing I/O unit.  This is what makes
    //  ChatGPT-style simultaneous loud-speaker playback + clean mic capture
    //  possible: the DSP cancels speaker bleed so KWS only hears the user.
    //
    //  .defaultToSpeaker  ← routes output to speaker (loud) by default,
    //  identical to overrideOutputAudioPort(.speaker) but set at category
    //  level so it survives session reactivations.
    // ─────────────────────────────────────────────────────────────────────
    private func activateSession() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .voiceChat,
                          options: [.allowBluetooth, .defaultToSpeaker])
        try s.setActive(true)

        print("[NativeAudio] session active: sr=\(s.sampleRate) route=\(s.currentRoute.outputs.map{$0.portType.rawValue})")
    }

    // ─────────────────────────────────────────────────────────────────────
    //  setupPlaybackEngine — wires playerNode into playbackEngine only.
    //  Never touches recordEngine.
    // ─────────────────────────────────────────────────────────────────────
    private func setupPlaybackEngine() throws {
        print("[NativeAudio] setupPlaybackEngine()")
        playbackEngine.attach(playerNode)
        guard let playFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: playbackSampleRate,
                                          channels: playbackChannels,
                                          interleaved: false) else {
            throw NSError(domain: "NativeAudio", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create playback format"])
        }
        playbackEngine.connect(playerNode, to: playbackEngine.mainMixerNode, format: playFmt)
        print("[NativeAudio] setupPlaybackEngine() fmt=\(playFmt.sampleRate)Hz Float32")
        playbackReady = true
    }

    // ─────────────────────────────────────────────────────────────────────
    //  startRecording
    //
    //  Key rules for AVAudioEngine recording:
    //   1. Install tap with format:nil — let engine pick the hw format.
    //      Any explicit format risks a "format mismatch" crash.
    //   2. If engine is already running (TTS playing), stop it first,
    //      install the tap, then restart — new tap nodes need a restart.
    //   3. engine.start() goes AFTER installTap.
    // ─────────────────────────────────────────────────────────────────────
    private func startRecording(result: FlutterResult) {
        print("[NativeAudio] startRecording() isRecording=\(isRecording) recEngineRunning=\(recordEngine.isRunning)")
        guard !isRecording else { result(true); return }
        do {
            try activateSession()

            // Remove any stale tap
            recordEngine.inputNode.removeTap(onBus: 0)

            // Stop recordEngine if running before installing new tap
            if recordEngine.isRunning {
                recordEngine.stop()
                print("[NativeAudio] startRecording() recordEngine stopped to apply tap")
            }

            guard let targetFmt = recordTargetFmt else {
                throw NSError(domain: "NativeAudio", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "Cannot create 16kHz PCM-16 format"])
            }

            // nil format → engine picks native hw format
            recordEngine.inputNode.installTap(onBus: 0, bufferSize: tapBufferSize,
                                              format: nil) { [weak self] buf, _ in
                guard let self = self, let tgt = self.recordTargetFmt else { return }
                guard let converted = self.convertBuffer(buf, to: tgt) else { return }
                let data = self.pcmBufferToData(converted)
                guard !data.isEmpty else { return }
                DispatchQueue.main.async {
                    self.eventSink?(FlutterStandardTypedData(bytes: data))
                }
            }

            let actualFmt = recordEngine.inputNode.outputFormat(forBus: 0)
            print("[NativeAudio] startRecording() tap hw=\(actualFmt.sampleRate)Hz \(actualFmt.channelCount)ch")

            try activateSession()  // re-activate right before start
            try recordEngine.start()
            isRecording = true
            recordEngineReady = true
            print("[NativeAudio] startRecording() DONE recordEngine running")
            result(true)
        } catch {
            print("[NativeAudio] startRecording() FAILED: \(error)")
            result(FlutterError(code: "REC_ERROR",
                                message: error.localizedDescription, details: "\(error)"))
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    //  stopRecording
    //  Removes the mic tap and stops the engine.
    //
    //  Session stays .playAndRecord — we MUST NOT switch to .playback here.
    //  AVAudioEngine's inputNode is permanently wired into the graph; if
    //  engine.start() is ever called with a .playback-only session, CoreAudio
    //  runs InitializeActiveNodesInInputChain → -10868 crash.
    //  Keeping .playAndRecord is safe: the red mic indicator disappears as
    //  soon as the tap is removed (no tap = no active capture).
    //  The engine is left stopped; playWav() starts it lazily.
    // ─────────────────────────────────────────────────────────────────────
    private func stopRecording(result: FlutterResult) {
        print("[NativeAudio] stopRecording() isRecording=\(isRecording)")
        guard isRecording else { result(true); return }

        recordEngine.inputNode.removeTap(onBus: 0)
        isRecording = false
        recordEngineReady = false
        recordEngine.stop()
        print("[NativeAudio] stopRecording() recordEngine stopped, tap removed")

        // Refresh session — playbackEngine continues running unaffected
        do { try activateSession() } catch {
            print("[NativeAudio] stopRecording() session refresh failed: \(error)")
        }
        result(true)
    }

    // ─────────────────────────────────────────────────────────────────────
    //  playWav
    //  Parses WAV header in memory (no disk I/O), converts to the playerNode
    //  connection format (Float32 @ playbackSampleRate), then schedules.
    //
    //  AVAudioPlayerNode.scheduleBuffer requires the buffer format to EXACTLY
    //  match the node's connection format.  The WAV from Flutter is Int16 PCM
    //  (wav_utils.dart always writes 16-bit), so we must convert to Float32
    //  before scheduling — otherwise the bytes are reinterpreted → noise.
    // ─────────────────────────────────────────────────────────────────────
    private func playWav(data: Data, result: FlutterResult) {
        print("[NativeAudio] playWav() \(data.count)B playbackReady=\(playbackReady) running=\(playbackEngine.isRunning)")
        do {
            // Ensure playbackEngine is set up and running
            if !playbackReady {
                try activateSession()
                try setupPlaybackEngine()
            }
            if !playbackEngine.isRunning {
                try activateSession()
                try playbackEngine.start()
                print("[NativeAudio] playWav() playbackEngine restarted")
            }

            guard let rawBuffer = try wavDataToPCMBuffer(data) else {
                print("[NativeAudio] playWav() decode failed for \(data.count)B")
                result(FlutterError(code: "WAV_ERROR",
                                    message: "Cannot decode WAV (\(data.count) bytes)",
                                    details: nil)); return
            }

            guard let playFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                              sampleRate: playbackSampleRate,
                                              channels: playbackChannels,
                                              interleaved: false) else {
                result(FlutterError(code: "PLAY_ERROR",
                                    message: "Cannot create playback format", details: nil)); return
            }

            let buffer: AVAudioPCMBuffer
            if rawBuffer.format == playFmt {
                buffer = rawBuffer
            } else {
                guard let converted = convertBuffer(rawBuffer, to: playFmt) else {
                    result(FlutterError(code: "PLAY_ERROR",
                                        message: "Format conversion failed \(rawBuffer.format.sampleRate)Hz → Float32@\(playbackSampleRate)",
                                        details: nil)); return
                }
                print("[NativeAudio] playWav() converted \(rawBuffer.format.sampleRate)Hz → Float32@\(playbackSampleRate)")
                buffer = converted
            }

            print("[NativeAudio] playWav() scheduling \(buffer.frameLength)fr @ \(buffer.format.sampleRate)Hz")
            // Always ensure playerNode is in playing state right before
            // scheduling. If stopPlayback() was called, playerNode.stop()
            // exits the playing state — play() here re-enters it so the
            // buffer renders immediately.
            if !playerNode.isPlaying { playerNode.play() }
            playerNode.scheduleBuffer(buffer) {
                print("[NativeAudio] playWav() chunk done \(buffer.frameLength)fr")
            }
            result(true)
        } catch {
            print("[NativeAudio] playWav() FAILED: \(error)")
            result(FlutterError(code: "PLAY_ERROR",
                                message: error.localizedDescription, details: "\(error)"))
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    //  stopPlayback
    // ─────────────────────────────────────────────────────────────────────
    private func stopPlayback(result: FlutterResult) {
        print("[NativeAudio] stopPlayback()")
        // stop() flushes all pending scheduled buffers and dequeues everything.
        // We do NOT call playerNode.play() here — the node will be put back
        // into playing state by the next playWav() call. Calling play() on a
        // node with no buffers queued immediately puts it into a "starved"
        // state where subsequent scheduleBuffer calls are silently dropped.
        playerNode.stop()
        result(true)
    }

    // ─────────────────────────────────────────────────────────────────────
    //  setSpeaker
    //  Keeps mode: .voiceChat so AEC stays active regardless of routing.
    //  .defaultToSpeaker is already set at category level; for earpiece we
    //  use overrideOutputAudioPort(.none).
    // ─────────────────────────────────────────────────────────────────────
    private func setSpeaker(enabled: Bool, result: FlutterResult) {
        print("[NativeAudio] setSpeaker() enabled=\(enabled)")
        do {
            let s = AVAudioSession.sharedInstance()
            // Re-apply category with voiceChat mode to keep AEC active
            try s.setCategory(.playAndRecord, mode: .voiceChat,
                              options: [.allowBluetooth, .defaultToSpeaker])
            try s.setActive(true)
            try s.overrideOutputAudioPort(enabled ? .speaker : .none)
            print("[NativeAudio] setSpeaker() route=\(s.currentRoute.outputs.map{$0.portType.rawValue})")
            result(true)
        } catch {
            print("[NativeAudio] setSpeaker() FAILED: \(error)")
            result(FlutterError(code: "SESSION_ERROR",
                                message: error.localizedDescription, details: "\(error)"))
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Permissions
    // ─────────────────────────────────────────────────────────────────────
    private func hasPermission(result: FlutterResult) {
        let p = AVAudioSession.sharedInstance().recordPermission
        print("[NativeAudio] hasPermission() \(p.rawValue)")
        result(p == .granted)
    }

    private func requestPermission(result: @escaping FlutterResult) {
        print("[NativeAudio] requestPermission()")
        AVAudioSession.sharedInstance().requestRecordPermission { granted in
            print("[NativeAudio] requestPermission() granted=\(granted)")
            DispatchQueue.main.async { result(granted) }
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Session notifications
    // ─────────────────────────────────────────────────────────────────────
    private func subscribeToAudioSessionNotifications() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleInterruption(_:)),
                       name: AVAudioSession.interruptionNotification,
                       object: AVAudioSession.sharedInstance())
        nc.addObserver(self, selector: #selector(handleRouteChange(_:)),
                       name: AVAudioSession.routeChangeNotification,
                       object: AVAudioSession.sharedInstance())
    }

    @objc private func handleInterruption(_ n: Notification) {
        guard let info = n.userInfo,
              let t = (info[AVAudioSessionInterruptionTypeKey] as? UInt)
                        .flatMap(AVAudioSession.InterruptionType.init(rawValue:)) else { return }
        switch t {
        case .began:
            print("[NativeAudio] interruption BEGAN playback=\(playbackEngine.isRunning) record=\(recordEngine.isRunning)")
        case .ended:
            let opts = AVAudioSession.InterruptionOptions(
                rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            print("[NativeAudio] interruption ENDED shouldResume=\(opts.contains(.shouldResume))")
            guard opts.contains(.shouldResume) else { return }
            do {
                try activateSession()
                if playbackReady && !playbackEngine.isRunning {
                    try playbackEngine.start()
                    if !playerNode.isPlaying { playerNode.play() }
                }
                if recordEngineReady && !recordEngine.isRunning { try recordEngine.start() }
                print("[NativeAudio] interruption: engines resumed")
            } catch {
                print("[NativeAudio] interruption resume failed: \(error)")
            }
        @unknown default: break
        }
    }

    @objc private func handleRouteChange(_ n: Notification) {
        let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
        let outs = AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue }
        print("[NativeAudio] routeChange reason=\(reason) outputs=\(outs)")

        // reason 2 = oldDeviceUnavailable (headphones unplugged, BT disconnected)
        if reason == 2 && playbackReady {
            print("[NativeAudio] routeChange: device removed, restarting playbackEngine")
            playbackEngine.stop()
            do {
                try activateSession()
                try playbackEngine.start()
                if !playerNode.isPlaying { playerNode.play() }
                print("[NativeAudio] routeChange: playbackEngine restarted")
            } catch {
                print("[NativeAudio] routeChange: playbackEngine restart failed: \(error)")
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    //  Private helpers
    // ─────────────────────────────────────────────────────────────────────

    /// Convert source PCM buffer to targetFormat using AVAudioConverter.
    private func convertBuffer(_ source: AVAudioPCMBuffer,
                                to targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: source.format, to: targetFormat) else {
            print("[NativeAudio] convertBuffer: no converter \(source.format.sampleRate)->\(targetFormat.sampleRate)")
            return nil
        }
        let ratio      = targetFormat.sampleRate / source.format.sampleRate
        let frameCount = AVAudioFrameCount(max(1, Double(source.frameLength) * ratio))
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                            frameCapacity: frameCount) else { return nil }
        var err: NSError?
        var consumed = false
        converter.convert(to: output, error: &err) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return source
        }
        if let e = err { print("[NativeAudio] convertBuffer error: \(e)"); return nil }
        return output
    }

    /// Extract raw bytes from a PCM Int16 interleaved buffer.
    private func pcmBufferToData(_ buffer: AVAudioPCMBuffer) -> Data {
        guard let ptr = buffer.int16ChannelData else { return Data() }
        return Data(bytes: ptr[0], count: Int(buffer.frameLength) * MemoryLayout<Int16>.size)
    }

    /// Parse WAV header in memory and return a PCMBuffer — no disk I/O.
    /// Supports standard PCM WAV (fmt chunk + data chunk).
    private func wavDataToPCMBuffer(_ data: Data) throws -> AVAudioPCMBuffer? {
        print("[NativeAudio] wavDataToPCMBuffer() \(data.count)B")
        guard data.count > 44 else {
            print("[NativeAudio] wavDataToPCMBuffer() too small"); return nil
        }

        // ── Parse fmt chunk ────────────────────────────────────────────────
        // Bytes 0-3: "RIFF", 4-7: file size, 8-11: "WAVE"
        // Bytes 12-15: "fmt ", 16-19: chunk size (16 for PCM)
        let numChannels: UInt32 = data.withUnsafeBytes { buffer in
            let byte0 = buffer[22]
            let byte1 = buffer[23]
            return UInt32((UInt16(byte1) << 8) | UInt16(byte0))
        }
        let sampleRateRaw: UInt32 = data.withUnsafeBytes { buffer in
            let byte0 = UInt32(buffer[24])
            let byte1 = UInt32(buffer[25])
            let byte2 = UInt32(buffer[26])
            let byte3 = UInt32(buffer[27])
            return byte0 | (byte1 << 8) | (byte2 << 16) | (byte3 << 24)
        }
        let bitsPerSample: UInt16 = data.withUnsafeBytes { buffer in
            let byte0 = UInt16(buffer[34])
            let byte1 = UInt16(buffer[35])
            return byte0 | (byte1 << 8)
        }

        // All WAV fields are little-endian; Swift on ARM is also LE — no swap needed.
        let channels   = UInt32(numChannels)
        let sampleRate = Double(sampleRateRaw)
        let bits       = Int(bitsPerSample)
        print("[NativeAudio] wavDataToPCMBuffer() sr=\(sampleRate) ch=\(channels) bits=\(bits)")

        // ── Find data chunk ────────────────────────────────────────────────
        var dataOffset = 12
        var dataSize   = 0
        while dataOffset + 8 <= data.count {
            let tag = data.subdata(in: dataOffset..<(dataOffset + 4))
            let chunkSize: UInt32 = data.withUnsafeBytes { buffer in
                let byte0 = UInt32(buffer[dataOffset + 4])
                let byte1 = UInt32(buffer[dataOffset + 5])
                let byte2 = UInt32(buffer[dataOffset + 6])
                let byte3 = UInt32(buffer[dataOffset + 7])
                return byte0 | (byte1 << 8) | (byte2 << 16) | (byte3 << 24)
            }
            if tag == Data("data".utf8) {
                dataOffset += 8
                dataSize    = Int(chunkSize)
                break
            }
            dataOffset += 8 + Int(chunkSize)
        }
        guard dataSize > 0, dataOffset + dataSize <= data.count else {
            print("[NativeAudio] wavDataToPCMBuffer() data chunk not found"); return nil
        }

        // ── Build AVAudioFormat ────────────────────────────────────────────
        let commonFmt: AVAudioCommonFormat = bits == 32 ? .pcmFormatFloat32 : .pcmFormatInt16
        guard let fmt = AVAudioFormat(commonFormat: commonFmt,
                                      sampleRate: sampleRate,
                                      channels: AVAudioChannelCount(channels),
                                      interleaved: false) else {
            print("[NativeAudio] wavDataToPCMBuffer() cannot create AVAudioFormat"); return nil
        }

        let bytesPerFrame = (bits / 8) * Int(channels)
        let frameCount    = AVAudioFrameCount(dataSize / bytesPerFrame)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frameCount) else {
            print("[NativeAudio] wavDataToPCMBuffer() PCMBuffer alloc failed"); return nil
        }
        buf.frameLength = frameCount

        // ── Copy samples ───────────────────────────────────────────────────
        let rawBytes = [UInt8](data[dataOffset..<(dataOffset + dataSize)])
        if bits == 32, let f32 = buf.floatChannelData {
            // Float32 — de-interleave if stereo
            rawBytes.withUnsafeBytes { ptr in
                let floats = ptr.bindMemory(to: Float.self)
                for frame in 0..<Int(frameCount) {
                    for ch in 0..<Int(channels) {
                        f32[ch][frame] = floats[frame * Int(channels) + ch]
                    }
                }
            }
        } else if bits == 16, let i16 = buf.int16ChannelData {
            rawBytes.withUnsafeBytes { ptr in
                let shorts = ptr.bindMemory(to: Int16.self)
                for frame in 0..<Int(frameCount) {
                    for ch in 0..<Int(channels) {
                        i16[ch][frame] = shorts[frame * Int(channels) + ch]
                    }
                }
            }
        } else {
            // Unsupported bit depth — fall back to temp-file method
            print("[NativeAudio] wavDataToPCMBuffer() unsupported bits=\(bits), using file fallback")
            return try wavDataToPCMBufferViaFile(data)
        }

        print("[NativeAudio] wavDataToPCMBuffer() OK \(frameCount)fr \(sampleRate)Hz")
        return buf
    }

    /// Fallback: write to temp file and read with AVAudioFile.
    /// Used only for uncommon WAV formats (e.g. 24-bit).
    private func wavDataToPCMBufferViaFile(_ data: Data) throws -> AVAudioPCMBuffer? {
        let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString + ".wav")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let file = try AVAudioFile(forReading: tmp)
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: frameCount) else { return nil }
        try file.read(into: buf)
        return buf
    }
}
