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

    // ── Audio engine ──────────────────────────────────────────────────────
    private let engine     = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var isRecording = false
    private var engineReady = false

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
    //  configure
    //  Activates AVAudioSession and wires the engine graph.
    //  Does NOT start the engine — callers (playWav / startRecording) do that
    //  because each needs a different graph topology (with/without input tap).
    // ─────────────────────────────────────────────────────────────────────
    private func configure(result: FlutterResult) {
        print("[NativeAudio] configure() engineReady=\(engineReady)")
        do {
            try activateSession()
            if !engineReady { try setupEngine() }
            print("[NativeAudio] configure() DONE")
            result(true)
        } catch {
            print("[NativeAudio] configure() FAILED: \(error)")
            result(FlutterError(code: "CONFIGURE_ERROR",
                                message: error.localizedDescription, details: "\(error)"))
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    //  activateSession  — shared helper, always .default + defaultToSpeaker
    // ─────────────────────────────────────────────────────────────────────
    private func activateSession() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord, mode: .default,
                          options: [.allowBluetooth, .defaultToSpeaker])
        try s.setActive(true)
        print("[NativeAudio] session active: sr=\(s.sampleRate) route=\(s.currentRoute.outputs.map{$0.portType.rawValue})")
    }

    // ─────────────────────────────────────────────────────────────────────
    //  setupEngine  — attach + connect playerNode; does NOT start the engine
    // ─────────────────────────────────────────────────────────────────────
    private func setupEngine() throws {
        print("[NativeAudio] setupEngine()")
        engine.attach(playerNode)

        guard let playFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: playbackSampleRate,
                                          channels: playbackChannels,
                                          interleaved: false) else {
            throw NSError(domain: "NativeAudio", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create playback format"])
        }
        engine.connect(playerNode, to: engine.mainMixerNode, format: playFmt)
        print("[NativeAudio] setupEngine() playFmt=\(playFmt.sampleRate)Hz \(playFmt.channelCount)ch")
        engine.prepare()
        engineReady = true
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
        print("[NativeAudio] startRecording() isRecording=\(isRecording) engineRunning=\(engine.isRunning)")
        guard !isRecording else { result(true); return }
        do {
            try activateSession()
            if !engineReady { try setupEngine() }

            // Remove any stale tap before installing a new one
            engine.inputNode.removeTap(onBus: 0)

            // Stop the engine if it was running (e.g. TTS was active).
            // AVAudioEngine requires a restart after topology changes.
            if engine.isRunning {
                engine.stop()
                print("[NativeAudio] startRecording() engine stopped to apply tap")
            }

            guard let targetFmt = recordTargetFmt else {
                throw NSError(domain: "NativeAudio", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: "Cannot create 16kHz PCM-16 format"])
            }

            // nil format → engine delivers buffers in native hw format
            engine.inputNode.installTap(onBus: 0, bufferSize: tapBufferSize,
                                        format: nil) { [weak self] buf, _ in
                guard let self = self, let tgt = self.recordTargetFmt else { return }
                guard let converted = self.convertBuffer(buf, to: tgt) else { return }
                let data = self.pcmBufferToData(converted)
                guard !data.isEmpty else { return }
                DispatchQueue.main.async {
                    self.eventSink?(FlutterStandardTypedData(bytes: data))
                }
            }

            let actualFmt = engine.inputNode.outputFormat(forBus: 0)
            print("[NativeAudio] startRecording() tap installed hw=\(actualFmt.sampleRate)Hz \(actualFmt.channelCount)ch")

            try engine.start()
            isRecording = true
            print("[NativeAudio] startRecording() DONE engine running")
            result(true)
        } catch {
            print("[NativeAudio] startRecording() FAILED: \(error)")
            result(FlutterError(code: "REC_ERROR",
                                message: error.localizedDescription, details: "\(error)"))
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    //  stopRecording
    //  Removes the tap, switches session to playback-only so iOS dismisses
    //  the red microphone indicator, then restarts the engine for TTS.
    // ─────────────────────────────────────────────────────────────────────
    private func stopRecording(result: FlutterResult) {
        print("[NativeAudio] stopRecording() isRecording=\(isRecording)")
        guard isRecording else { result(true); return }

        // 1. Remove the mic tap
        engine.inputNode.removeTap(onBus: 0)
        isRecording = false
        print("[NativeAudio] stopRecording() tap removed")

        // 2. Stop the engine before changing session category
        engine.stop()

        // 3. Switch to playback-only — this releases the microphone and
        //    dismisses the iOS red dot / microphone indicator.
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback, mode: .default, options: [.allowBluetooth])
            try s.setActive(true)
            print("[NativeAudio] stopRecording() session -> playback (mic released)")
        } catch {
            print("[NativeAudio] stopRecording() session switch failed: \(error)")
        }

        // 4. Restart engine so TTS can play immediately
        do {
            try engine.start()
            print("[NativeAudio] stopRecording() engine restarted for TTS")
        } catch {
            print("[NativeAudio] stopRecording() engine restart failed: \(error)")
        }

        result(true)
    }

    // ─────────────────────────────────────────────────────────────────────
    //  playWav
    //  Parses WAV header in memory (no disk I/O), schedules the buffer.
    // ─────────────────────────────────────────────────────────────────────
    private func playWav(data: Data, result: FlutterResult) {
        print("[NativeAudio] playWav() \(data.count)B engineReady=\(engineReady) running=\(engine.isRunning)")
        do {
            if !engineReady {
                try activateSession()
                try setupEngine()
            }
            // If engine stopped (e.g. after stopRecording switched to .playback),
            // ensure session is active (stays .playback if mic not needed) and restart.
            if !engine.isRunning {
                let s = AVAudioSession.sharedInstance()
                if s.category != .playAndRecord && s.category != .playback {
                    try s.setCategory(.playback, mode: .default, options: [.allowBluetooth])
                }
                try s.setActive(true)
                try engine.start()
                print("[NativeAudio] playWav() engine started")
            }

            guard let buffer = try wavDataToPCMBuffer(data) else {
                print("[NativeAudio] playWav() decode failed for \(data.count)B")
                result(FlutterError(code: "WAV_ERROR",
                                    message: "Cannot decode WAV (\(data.count) bytes)",
                                    details: nil)); return
            }
            let bFmt = buffer.format
            print("[NativeAudio] playWav() buffer: \(buffer.frameLength)fr \(bFmt.sampleRate)Hz \(bFmt.channelCount)ch")

            playerNode.scheduleBuffer(buffer) {
                print("[NativeAudio] playWav() chunk done \(buffer.frameLength)fr")
            }
            if !playerNode.isPlaying { playerNode.play() }
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
        playerNode.stop()
        result(true)
    }

    // ─────────────────────────────────────────────────────────────────────
    //  setSpeaker
    //  Uses .default mode + overrideOutputAudioPort for both paths.
    //  Avoids .voiceChat / .videoChat which force system-level routing.
    // ─────────────────────────────────────────────────────────────────────
    private func setSpeaker(enabled: Bool, result: FlutterResult) {
        print("[NativeAudio] setSpeaker() enabled=\(enabled)")
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord, mode: .default,
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
            print("[NativeAudio] interruption BEGAN engine=\(engine.isRunning)")
        case .ended:
            let opts = AVAudioSession.InterruptionOptions(
                rawValue: info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            print("[NativeAudio] interruption ENDED shouldResume=\(opts.contains(.shouldResume))")
            guard opts.contains(.shouldResume), engineReady else { return }
            do {
                try activateSession()
                if !engine.isRunning { try engine.start() }
                print("[NativeAudio] interruption: engine resumed")
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
        // The engine's output node format is now invalid — must restart.
        if reason == 2 && engineReady {
            print("[NativeAudio] routeChange: device removed, restarting engine")
            engine.stop()
            do {
                try activateSession()
                try engine.start()
                print("[NativeAudio] routeChange: engine restarted")
            } catch {
                print("[NativeAudio] routeChange: engine restart failed: \(error)")
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
        let numChannels: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: 22, as: UInt16.self) }.bigEndianToHost() == 0
            ? UInt32(data.withUnsafeBytes { $0.load(fromByteOffset: 22, as: UInt16.self) })
            : UInt32(data.withUnsafeBytes { $0.load(fromByteOffset: 22, as: UInt16.self) })
        let sampleRateRaw: UInt32 = data.withUnsafeBytes { $0.load(fromByteOffset: 24, as: UInt32.self) }
        let bitsPerSample: UInt16 = data.withUnsafeBytes { $0.load(fromByteOffset: 34, as: UInt16.self) }

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
            let chunkSize: UInt32 = data.withUnsafeBytes {
                $0.load(fromByteOffset: dataOffset + 4, as: UInt32.self)
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
