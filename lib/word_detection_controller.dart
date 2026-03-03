import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';

import 'voice_agent/audio_session_manager.dart';
import 'voice_agent/audio_utils.dart';
import 'voice_agent/kws_engine.dart';

enum WordDetectionState {
  idle,
  listening,
}

class WordDetectionController extends ChangeNotifier {
  WordDetectionController({
    this.sampleRate = 16000,
  });

  final int sampleRate;
  final AudioRecorder _recorder = AudioRecorder();

  StreamSubscription<Uint8List>? _audioSub;
  KwsEngine? _kwsEngine;

  WordDetectionState _state = WordDetectionState.idle;
  String _detectedWord = '';
  List<String> _detectionHistory = [];
  String? _lastError;

  // Keywords MUST match EXACTLY the format in keywords.txt (BPE tokenized)
  // Generated via: sherpa-onnx-cli text2token --tokens tokens.txt --tokens-type bpe --bpe-model bpe.model keywords_raw.txt keywords.txt
  final List<String> _keywords = [
    '▁ST O P',
    '▁HE LL O',
    '▁HO L D ▁ON',
  ];

  WordDetectionState get state => _state;
  String get detectedWord => _detectedWord;
  List<String> get detectionHistory => _detectionHistory;
  String? get lastError => _lastError;
  List<String> get keywords => _keywords;

  Future<void> start() async {
    if (_state != WordDetectionState.idle) return;
    _lastError = null;

    try {
      await AudioSessionManager.configure();
      await _ensureKwsEngine();

      final hasPermission = await _recorder.hasPermission();
      if (!hasPermission) {
        _lastError = 'Microphone permission denied.';
        notifyListeners();
        return;
      }

      final stream = await _recorder.startStream(
        RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          numChannels: 1,
          sampleRate: sampleRate,
          autoGain: true,
          echoCancel: true,
          noiseSuppress: true,
        ),
      );

      _audioSub = stream.listen(
        _onAudioData,
        onError: (Object error) {
          _lastError = error.toString();
          notifyListeners();
        },
      );

      _state = WordDetectionState.listening;
      _detectedWord = '';
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    }
  }

  Future<void> stop() async {
    await _audioSub?.cancel();
    _audioSub = null;
    await _recorder.stop();
    await AudioSessionManager.deactivate();
    _kwsEngine?.reset();
    _state = WordDetectionState.idle;
    _detectedWord = '';
    notifyListeners();
  }

  Future<void> _ensureKwsEngine() async {
    if (_kwsEngine != null) return;

    try {
      _kwsEngine = await KwsEngine.create(
        modelPath: 'assets/models/kws',
        encoderFile: 'encoder-epoch-12-avg-2-chunk-16-left-64.onnx',
        decoderFile: 'decoder-epoch-12-avg-2-chunk-16-left-64.onnx',
        joinerFile: 'joiner-epoch-12-avg-2-chunk-16-left-64.onnx',
        tokensFile: 'tokens.txt',
        keywords: _keywords,
        keywordsThreshold: 0.25,
      );
    } catch (e) {
      _lastError = 'Failed to load KWS model: $e';
      rethrow;
    }
  }

  void _onAudioData(Uint8List data) {
    if (_kwsEngine == null) return;
    if (data.isEmpty) return;

    final samples = pcm16BytesToFloat32(data);

    // Debug: Log audio processing
    if (samples.isNotEmpty) {
      debugPrint('KWS: Processing ${samples.length} audio samples');
    }

    // Check for keyword detection
    final detectedKeyword = _kwsEngine!.update(samples: samples);

    // Debug: Log detection result
    debugPrint('KWS: Detection result: "$detectedKeyword"');

    if (detectedKeyword != null && detectedKeyword.isNotEmpty) {
      debugPrint('KWS: ✅ KEYWORD DETECTED: "$detectedKeyword"');
      _detectedWord = detectedKeyword;
      _addToHistory(detectedKeyword);
      notifyListeners();

      // Auto-reset detection after showing
      Future.delayed(const Duration(milliseconds: 500), () {
        if (_detectedWord == detectedKeyword) {
          _detectedWord = '';
          notifyListeners();
        }
      });
    }
  }

  void _addToHistory(String word) {
    final timestamp = DateTime.now();
    final entry = '${timestamp.hour.toString().padLeft(2, '0')}:'
        '${timestamp.minute.toString().padLeft(2, '0')}:'
        '${timestamp.second.toString().padLeft(2, '0')} - $word';
    _detectionHistory.insert(0, entry);
    if (_detectionHistory.length > 20) {
      _detectionHistory.removeLast();
    }
  }

  void clearHistory() {
    _detectionHistory.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _audioSub?.cancel();
    _recorder.dispose();
    _kwsEngine?.dispose();
    super.dispose();
  }
}
