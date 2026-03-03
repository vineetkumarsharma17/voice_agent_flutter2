import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart';

import 'asset_utils.dart';
import 'model_registry.dart';

class VadEngine {
  VadEngine._(this._vad);

  final VoiceActivityDetector _vad;
  bool _inSpeech = false;

  static Future<VadEngine> create({VadSettings settings = const VadSettings()}) async {
    final modelPath = await copyAssetFile(ModelRegistry.vadModelAsset);
    final config = VadModelConfig(
      sileroVad: SileroVadModelConfig(
        model: modelPath,
        threshold: settings.threshold,
        minSilenceDuration: settings.minSilenceDuration,
        minSpeechDuration: settings.minSpeechDuration,
        maxSpeechDuration: settings.maxSpeechDuration,
        windowSize: settings.windowSize,
      ),
      sampleRate: settings.sampleRate,
    );
    final vad = VoiceActivityDetector(config: config, bufferSizeInSeconds: 30.0);
    return VadEngine._(vad);
  }

  VadEvent update({required List<double> samples, required int sampleRate}) {
    _vad.acceptWaveform(Float32List.fromList(samples));
    final detected = _vad.isDetected();
    if (!_inSpeech && detected) {
      _inSpeech = true;
      return VadEvent.speechStart;
    }
    if (_inSpeech && !detected) {
      _inSpeech = false;
      return VadEvent.speechEnd;
    }
    return detected ? VadEvent.speech : VadEvent.silence;
  }

  void reset() {
    _vad.flush();
    _inSpeech = false;
  }

  void dispose() {
    _vad.free();
  }
}

enum VadEvent {
  silence,
  speech,
  speechStart,
  speechEnd,
}

class VadSettings {
  const VadSettings({
    this.threshold = 0.6,
    this.minSilenceDuration = 0.3,
    this.minSpeechDuration = 0.15,
    this.maxSpeechDuration = 20.0,
    this.sampleRate = 16000,
    this.windowSize = 512,
  });

  final double threshold;
  final double minSilenceDuration;
  final double minSpeechDuration;
  final double maxSpeechDuration;
  final int sampleRate;
  final int windowSize;
}
