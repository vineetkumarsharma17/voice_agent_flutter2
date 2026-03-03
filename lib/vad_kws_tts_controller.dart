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

  KwsState _kwsState = KwsState.idle;
  String _lastDetectedWord = '';
  final List<KwsDetectionEvent> _detectionHistory = [];
  String? _kwsError;

  // Keywords — same format as WordDetectionController
  final List<String> keywords = const ['▁ST O P', '▁HE LL O', '▁HO L D ▁ON'];

  // ── TTS ──────────────────────────────────────────────────────────────────
  final AudioPlayer _player = AudioPlayer();
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
          autoGain: true,
          echoCancel: true,
          noiseSuppress: true,
        ),
      );

      _audioSub = stream.listen(
        _onAudioData,
        onError: (Object err) {
          _kwsError = err.toString();
          notifyListeners();
        },
      );

      _kwsState = KwsState.listening;
      notifyListeners();
    } catch (e) {
      _kwsError = e.toString();
      _kwsState = KwsState.idle;
      notifyListeners();
    }
  }

  Future<void> stopKws() async {
    await _audioSub?.cancel();
    _audioSub = null;
    await _recorder.stop();
    _kwsEngine?.reset();
    _kwsState = KwsState.idle;
    _lastDetectedWord = '';
    notifyListeners();
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
          await _player.setAudioSource(
            playlist,
            initialIndex: 0,
            initialPosition: Duration.zero,
          );
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
    _audioSub?.cancel();
    _recorder.dispose();
    _kwsEngine?.dispose();
    _player.dispose();
    _ttsEngine?.dispose();
    super.dispose();
  }
}
