import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:record/record.dart';

import 'voice_agent/audio_session_manager.dart';
import 'voice_agent/audio_utils.dart';
import 'voice_agent/kws_engine.dart';
import 'voice_agent/model_registry.dart';
import 'voice_agent/tts_engine.dart';
import 'voice_agent/wav_utils.dart';

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
class VadKwsTtsController extends ChangeNotifier {
  static const int _sampleRate = 16000;

  // ── KWS ──────────────────────────────────────────────────────────────────
  final AudioRecorder _recorder = AudioRecorder();
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
  late final AudioPlayer _player = AudioPlayer(
    // Let the player run but don't let it interrupt other audio
    handleInterruptions: false,
    androidApplyAudioAttributes:
        true, // Changed: we need to apply custom attributes
    handleAudioSessionActivation: false,
    audioLoadConfiguration: const AudioLoadConfiguration(
      androidLoadControl: AndroidLoadControl(
        // Prevent buffering from causing issues
        // minBufferDuration must be >= bufferForPlaybackMs and bufferForPlaybackAfterRebufferMs
        minBufferDuration: Duration(milliseconds: 2500),
        maxBufferDuration: Duration(seconds: 5),
        bufferForPlaybackDuration: Duration(milliseconds: 500),
        bufferForPlaybackAfterRebufferDuration: Duration(milliseconds: 1000),
      ),
    ),
  );
  TtsEngine? _ttsEngine;

  TtsState _ttsState = TtsState.idle;
  int _ttsToken = 0;
  String? _ttsError;
  String _ttsStatusDetail = '';

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
      await AudioSessionManager.configure();

      // If engine somehow not loaded yet, load it now.
      if (_kwsEngine == null) {
        _kwsState = KwsState.loading;
        notifyListeners();
        await _ensureKwsEngine();
      }

      final ok = await _recorder.hasPermission();
      if (!ok) {
        _kwsError = 'Microphone permission denied.';
        _kwsState = KwsState.idle;
        notifyListeners();
        return;
      }

      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          numChannels: 1,
          sampleRate: _sampleRate,
          autoGain: false,
          echoCancel:
              true, // IMPORTANT: Enable echo cancellation to prevent feedback from speaker
          noiseSuppress: false,
          androidConfig: AndroidRecordConfig(
            // CRITICAL: Use VOICE_RECOGNITION source - it doesn't pause on audio focus loss
            // and is designed to work while other audio plays
            audioSource: AndroidAudioSource.voiceRecognition,
          ),
        ),
      );

      _audioSub = stream.listen(
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
    await _recorder.stop();
    _kwsEngine?.reset();
    _kwsState = KwsState.idle;
    _lastDetectedWord = '';
    notifyListeners();
  }

  void _startAudioHealthCheck() {
    _lastAudioReceived = DateTime.now();
    _audioHealthCheck?.cancel();
    _audioHealthCheck = Timer.periodic(const Duration(seconds: 1), (timer) {
      final now = DateTime.now();
      final lastReceived = _lastAudioReceived;

      if (lastReceived != null &&
          now.difference(lastReceived).inSeconds > 2 &&
          _kwsState == KwsState.listening) {
        debugPrint(
            '[KWS] ⚠️ No audio received for 2s - audio focus likely lost. Attempting restart...');
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
      await _recorder.stop();

      // Small delay
      await Future.delayed(const Duration(milliseconds: 100));

      // Restart stream
      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          numChannels: 1,
          sampleRate: _sampleRate,
          autoGain: false,
          echoCancel:
              true, // IMPORTANT: Enable echo cancellation to prevent feedback from speaker
          noiseSuppress: false,
          androidConfig: AndroidRecordConfig(
            audioSource: AndroidAudioSource.voiceRecognition,
          ),
        ),
      );

      _audioSub = stream.listen(
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

    // Reconfigure audio session to ensure playback goes to speaker
    // and doesn't interrupt the mic recording.
    try {
      await AudioSessionManager.configure();
    } catch (e) {
      debugPrint('[TTS] Warning: Failed to configure audio session: $e');
    }

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

      bool firstChunk = true;
      final playlist = ConcatenatingAudioSource(children: []);
      await _player.stop();

      if (_ttsToken != thisToken) return;

      await for (final chunk in stream) {
        if (_ttsToken != thisToken) {
          _ttsEngine!.stopStream();
          break;
        }
        final wavBytes = wavBytesFromSamples(chunk.samples, chunk.sampleRate);
        await playlist.add(BytesAudioSource(wavBytes));

        if (firstChunk) {
          firstChunk = false;

          // Set audio attributes to NOT request audio focus
          // This prevents the recorder from being paused
          await _player.setAudioSource(
            playlist,
            initialIndex: 0,
            initialPosition: Duration.zero,
            preload: false, // Don't preload to avoid early focus request
          );

          // Now play without requesting focus
          unawaited(_player.play());
          _ttsState = TtsState.playing;
          _ttsStatusDetail = 'Playing chunk 1…';
          notifyListeners();
        } else {
          _ttsStatusDetail = 'Playing… chunk ${chunk.chunkIndex + 1}';
          notifyListeners();
        }
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
    await _player.stop();
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
    _recorder.dispose();
    _kwsEngine?.dispose();
    _player.dispose();
    _ttsEngine?.dispose();
    super.dispose();
  }
}
