import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'voice_agent/audio_utils.dart';
import 'voice_agent/kws_engine.dart';
import 'voice_agent/model_registry.dart';
import 'voice_agent/tts_engine.dart';
import 'voice_agent/wav_utils.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  Native audio bridge (iOS only — uses NativeAudioChannel.swift)
//  All AVAudioSession ownership lives on the Swift side; Flutter never touches
//  record or just_audio for this controller.
// ─────────────────────────────────────────────────────────────────────────────
class _NativeAudio {
  static const _method = MethodChannel('com.voiceagent/native_audio');
  static const _event = EventChannel('com.voiceagent/native_audio_stream');

  static Future<bool> configure() =>
      _method.invokeMethod<bool>('configure').then((v) => v ?? false);
  static Future<bool> startRecording() =>
      _method.invokeMethod<bool>('startRecording').then((v) => v ?? false);
  static Future<bool> stopRecording() =>
      _method.invokeMethod<bool>('stopRecording').then((v) => v ?? false);
  static Future<bool> stopPlayback() =>
      _method.invokeMethod<bool>('stopPlayback').then((v) => v ?? false);
  static Future<bool> setSpeaker({required bool enabled}) =>
      _method.invokeMethod<bool>(
          'setSpeaker', {'enabled': enabled}).then((v) => v ?? false);
  static Future<bool> hasPermission() =>
      _method.invokeMethod<bool>('hasPermission').then((v) => v ?? false);
  static Future<bool> requestPermission() =>
      _method.invokeMethod<bool>('requestPermission').then((v) => v ?? false);

  static Future<bool> playWav(Uint8List wavBytes) =>
      _method.invokeMethod<bool>('playWav', {
        'wavBytes': Uint8List.fromList(wavBytes),
      }).then((v) => v ?? false);

  /// Broadcast stream of raw PCM-16 [Uint8List] buffers from the mic.
  static Stream<Uint8List> get audioStream =>
      _event.receiveBroadcastStream().map((event) {
        if (event is Uint8List) return event;
        // EventChannel delivers typed data as Uint8List on iOS
        return Uint8List.fromList((event as List).cast<int>());
      });
}

// ─────────────────────────────────────────────────────────────────────────────
//  State enums
// ─────────────────────────────────────────────────────────────────────────────

enum KwsState { idle, loading, listening }

enum TtsState { idle, loading, synthesising, playing, stopped }

// ─────────────────────────────────────────────────────────────────────────────
//  Detection event
// ─────────────────────────────────────────────────────────────────────────────

class KwsDetectionEvent {
  final String keyword;
  final DateTime timestamp;

  /// Whether TTS audio was playing at the moment of detection.
  final bool duringTts;

  KwsDetectionEvent({required this.keyword, required this.duringTts})
      : timestamp = DateTime.now();

  String get timeLabel {
    final h = timestamp.hour.toString().padLeft(2, '0');
    final m = timestamp.minute.toString().padLeft(2, '0');
    final s = timestamp.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Controller
// ─────────────────────────────────────────────────────────────────────────────

/// Controls simultaneous KWS (keyword spotting via mic) and TTS (audio
/// playback).  Both run independently — KWS always listens through the mic
/// while TTS plays through the speaker.
///
/// On iOS all audio I/O goes through [_NativeAudio] (NativeAudioChannel.swift)
/// so the AVAudioSession is owned entirely by native code and no Flutter plugin
/// can override it.
class VadKwsTtsController extends ChangeNotifier {
  // ── KWS ──────────────────────────────────────────────────────────────────
  StreamSubscription<Uint8List>? _audioSub;
  KwsEngine? _kwsEngine;
  Timer? _audioHealthCheck; // Monitor if audio stream is alive

  KwsState _kwsState = KwsState.idle;
  String _lastDetectedWord = '';
  final List<KwsDetectionEvent> _detectionHistory = [];
  String? _kwsError;
  DateTime? _lastAudioReceived; // Track last time we got audio data

  // Keywords — same format as WordDetectionController
  final List<String> keywords = const ['▁ST O P', '▁HE LL O', '▁HO L D ▁ON'];

  // ── TTS ──────────────────────────────────────────────────────────────────
  TtsEngine? _ttsEngine;

  TtsState _ttsState = TtsState.idle;
  int _ttsToken = 0;
  String? _ttsError;
  String _ttsStatusDetail = '';

  // ── Speaker Toggle ───────────────────────────────────────────────────────
  bool _isSpeakerOn = false; // Start with earpiece (speaker off)

  // ── Constructor ──────────────────────────────────────────────────────────
  VadKwsTtsController(); // No automatic speaker override - user controls it manually

  // ── Getters ───────────────────────────────────────────────────────────────

  KwsState get kwsState => _kwsState;
  TtsState get ttsState => _ttsState;

  String get lastDetectedWord => _lastDetectedWord;
  List<KwsDetectionEvent> get detectionHistory =>
      List.unmodifiable(_detectionHistory);
  String? get kwsError => _kwsError;
  String? get ttsError => _ttsError;
  String get ttsStatusDetail => _ttsStatusDetail;

  bool get kwsRunning => _kwsState == KwsState.listening;
  bool get ttsRunning =>
      _ttsState == TtsState.synthesising || _ttsState == TtsState.playing;

  bool get isSpeakerOn => _isSpeakerOn;

  // ─────────────────────────────────────────────────────────────────────────
  //  Initialisation — call once when the screen opens
  // ─────────────────────────────────────────────────────────────────────────

  /// Pre-loads both the KWS model and the TTS engine in parallel so the
  /// buttons are immediately ready when the user taps them.
  Future<void> initEngines() async {
    // Run both initialisations concurrently; failures are surfaced via the
    // respective error fields so the UI can show them independently.
    await Future.wait([_initKwsEngine(), _initTtsEngine()]);
  }

  Future<void> _initKwsEngine() async {
    if (_kwsEngine != null) return;
    _kwsState = KwsState.loading;
    notifyListeners();
    try {
      await _ensureKwsEngine();
      _kwsState = KwsState.idle;
    } catch (e) {
      _kwsError = 'KWS init failed: $e';
      _kwsState = KwsState.idle;
    }
    notifyListeners();
  }

  Future<void> _initTtsEngine() async {
    if (_ttsEngine != null) return;
    _ttsState = TtsState.loading;
    _ttsStatusDetail = 'Loading TTS engine…';
    notifyListeners();
    try {
      _ttsEngine = await TtsEngine.init();
      _ttsState = TtsState.idle;
      _ttsStatusDetail = '';
    } catch (e) {
      _ttsError = 'TTS init failed: $e';
      _ttsState = TtsState.idle;
      _ttsStatusDetail = '';
    }
    notifyListeners();
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  KWS API
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> startKws() async {
    if (_kwsState != KwsState.idle) return;

    _kwsError = null;
    notifyListeners();

    try {
      // Load the KWS engine FIRST — model loading can disturb CoreAudio
      // session state on iOS. configure() must come AFTER so the session
      // is activated as close as possible to startRecording().
      if (_kwsEngine == null) {
        _kwsState = KwsState.loading;
        notifyListeners();
        await _ensureKwsEngine();
      }

      // Configure native AVAudioSession (Swift side owns it entirely).
      // Called after KWS model load to ensure session is fresh.
      await _NativeAudio.configure();

      // Check / request mic permission through native channel
      final ok = await _NativeAudio.hasPermission().then(
          (v) => v ? Future.value(true) : _NativeAudio.requestPermission());
      if (!ok) {
        _kwsError = 'Microphone permission denied.';
        _kwsState = KwsState.idle;
        notifyListeners();
        return;
      }

      // Subscribe to the native PCM-16 stream BEFORE starting the hardware tap
      _audioSub = _NativeAudio.audioStream.listen(
        _onAudioData,
        onError: (Object err) {
          debugPrint('[KWS] ❌ Audio stream error: $err');
          _kwsError = err.toString();
          notifyListeners();
        },
        onDone: () {
          debugPrint('[KWS] ⚠️ Audio stream closed unexpectedly');
          if (_kwsState == KwsState.listening) {
            _kwsError = 'Audio stream stopped unexpectedly';
            _kwsState = KwsState.idle;
            notifyListeners();
          }
        },
        cancelOnError: false,
      );

      await _NativeAudio.startRecording();

      _kwsState = KwsState.listening;
      notifyListeners();

      // Start health check timer to detect if audio stream stops
      _startAudioHealthCheck();
    } catch (e) {
      _kwsError = e.toString();
      _kwsState = KwsState.idle;
      notifyListeners();
    }
  }

  Future<void> stopKws() async {
    _audioHealthCheck?.cancel();
    _audioHealthCheck = null;
    _lastAudioReceived = null;
    await _audioSub?.cancel();
    _audioSub = null;
    await _NativeAudio.stopRecording();
    _kwsEngine?.reset();
    _kwsState = KwsState.idle;
    _lastDetectedWord = '';
    notifyListeners();
  }

  void _startAudioHealthCheck() {
    _lastAudioReceived = DateTime.now();
    _audioHealthCheck?.cancel();
    _audioHealthCheck = Timer.periodic(const Duration(seconds: 2), (timer) {
      final now = DateTime.now();
      final lastReceived = _lastAudioReceived;

      if (lastReceived != null &&
          now.difference(lastReceived).inSeconds > 5 &&
          _kwsState == KwsState.listening) {
        debugPrint('[KWS] ⚠️ No audio received for 5s — attempting restart...');
        _restartKwsRecording();
      }
    });
  }

  Future<void> _restartKwsRecording() async {
    debugPrint('[KWS] 🔄 Restarting recording...');

    try {
      // Don't change state - keep it as "listening"
      await _audioSub?.cancel();
      _audioSub = null;
      await _NativeAudio.stopRecording();

      // Give the Swift side time to complete stopRecording + activateSession
      // before we call startRecording again.
      await Future.delayed(const Duration(milliseconds: 400));

      // Re-subscribe then restart the hardware tap
      _audioSub = _NativeAudio.audioStream.listen(
        _onAudioData,
        onError: (Object err) {
          debugPrint('[KWS] ❌ Audio stream error: $err');
          _kwsError = err.toString();
          notifyListeners();
        },
        onDone: () {
          debugPrint('[KWS] ⚠️ Audio stream closed unexpectedly');
          if (_kwsState == KwsState.listening) {
            _kwsError = 'Audio stream stopped unexpectedly';
            _kwsState = KwsState.idle;
            notifyListeners();
          }
        },
        cancelOnError: false,
      );

      await _NativeAudio.startRecording();
      _lastAudioReceived = DateTime.now();
      debugPrint('[KWS] ✅ Recording restarted successfully');
    } catch (e) {
      debugPrint('[KWS] ❌ Failed to restart recording: $e');
      _kwsError = 'Failed to restart: $e';
      _kwsState = KwsState.idle;
      notifyListeners();
    }
  }

  Future<void> _ensureKwsEngine() async {
    if (_kwsEngine != null) return;
    _kwsEngine = await KwsEngine.create(
      modelPath: 'assets/models/kws',
      encoderFile: 'encoder-epoch-12-avg-2-chunk-16-left-64.onnx',
      decoderFile: 'decoder-epoch-12-avg-2-chunk-16-left-64.onnx',
      joinerFile: 'joiner-epoch-12-avg-2-chunk-16-left-64.onnx',
      tokensFile: 'tokens.txt',
      keywords: keywords,
      keywordsThreshold: 0.25,
    );
  }

  void _onAudioData(Uint8List data) {
    if (_kwsEngine == null || data.isEmpty) return;

    _lastAudioReceived = DateTime.now(); // Update last received timestamp
    debugPrint('[KWS] 📡 Received audio: ${data.length} bytes');

    final samples = pcm16BytesToFloat32(data);
    final detected = _kwsEngine!.update(samples: samples);

    if (detected != null && detected.isNotEmpty) {
      debugPrint('[KWS] ✅ DETECTED: "$detected"  ttsPlaying=$ttsRunning');
      _lastDetectedWord = detected;
      _detectionHistory.insert(
        0,
        KwsDetectionEvent(keyword: detected, duringTts: ttsRunning),
      );
      if (_detectionHistory.length > 50) _detectionHistory.removeLast();
      notifyListeners();

      // Auto-clear the flash after 600 ms
      Future.delayed(const Duration(milliseconds: 600), () {
        if (_lastDetectedWord == detected) {
          _lastDetectedWord = '';
          notifyListeners();
        }
      });
    }
  }

  void clearHistory() {
    _detectionHistory.clear();
    notifyListeners();
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  Speaker Toggle API
  // ─────────────────────────────────────────────────────────────────────────

  /// Toggle between speaker and earpiece output (like WhatsApp calls)
  Future<void> toggleSpeaker() async {
    _isSpeakerOn = !_isSpeakerOn;
    notifyListeners();

    try {
      if (_isSpeakerOn) {
        debugPrint('[Audio] 🔊 Switching to SPEAKER');
        await _NativeAudio.setSpeaker(enabled: true);
      } else {
        debugPrint('[Audio] 📱 Switching to EARPIECE');
        await _NativeAudio.setSpeaker(enabled: false);
      }
    } catch (e) {
      debugPrint('[Audio] ❌ Failed to toggle speaker: $e');
      // Revert state on error
      _isSpeakerOn = !_isSpeakerOn;
      notifyListeners();
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  TTS API
  // ─────────────────────────────────────────────────────────────────────────

  Future<void> startTts(String text) async {
    if (ttsRunning) return;

    _ttsError = null;

    // If engine somehow not loaded yet, load it now.
    if (_ttsEngine == null) {
      await _initTtsEngine();
      if (_ttsEngine == null) return; // init failed, error already set
    }

    // Always configure the native audio session before playing.
    // This is idempotent — safe to call even if startKws already called it.
    await _NativeAudio.configure();

    final thisToken = ++_ttsToken;
    _ttsState = TtsState.synthesising;
    _ttsStatusDetail = 'Synthesising…';
    notifyListeners();

    try {
      final profile = ModelRegistry.languages[SupportedLanguage.enUS]!;
      final stream = _ttsEngine!.synthesizeStream(
        text: text,
        language: profile,
      );

      if (_ttsToken != thisToken) return;

      bool firstChunk = true;
      await for (final chunk in stream) {
        if (_ttsToken != thisToken) {
          _ttsEngine!.stopStream();
          break;
        }

        // Convert PCM samples → WAV bytes and send to native player
        final wavBytes = wavBytesFromSamples(chunk.samples, chunk.sampleRate);
        await _NativeAudio.playWav(wavBytes);

        if (firstChunk) {
          firstChunk = false;
          _ttsState = TtsState.playing;
          _ttsStatusDetail = 'Playing chunk 1…';
          notifyListeners();
        } else {
          _ttsStatusDetail = 'Playing… chunk ${chunk.chunkIndex + 1}';
          notifyListeners();
        }
      }

      // All chunks queued — mark as idle once the last chunk finishes
      if (_ttsToken == thisToken) {
        _ttsState = TtsState.idle;
        _ttsStatusDetail = '';
        notifyListeners();
      }
    } catch (e) {
      if (_ttsToken == thisToken) {
        _ttsError = e.toString();
        _ttsState = TtsState.idle;
        _ttsStatusDetail = '';
        notifyListeners();
      }
    }
  }

  Future<void> stopTts() async {
    _ttsToken++;
    _ttsEngine?.stopStream();
    await _NativeAudio.stopPlayback();
    _ttsState = TtsState.stopped;
    _ttsStatusDetail = 'Stopped.';
    notifyListeners();

    // Reset to idle after a beat so the button re-enables
    await Future.delayed(const Duration(milliseconds: 300));
    _ttsState = TtsState.idle;
    _ttsStatusDetail = '';
    notifyListeners();
  }

  // ─────────────────────────────────────────────────────────────────────────
  //  Dispose
  // ─────────────────────────────────────────────────────────────────────────

  @override
  void dispose() {
    _audioHealthCheck?.cancel();
    _audioSub?.cancel();
    _NativeAudio.stopRecording();
    _kwsEngine?.dispose();
    _NativeAudio.stopPlayback();
    _ttsEngine?.dispose();
    super.dispose();
  }
}
