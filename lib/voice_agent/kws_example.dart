// Example of how to use KwsEngine for voice interruption detection
// This is a reference implementation - not integrated into the main app yet

import 'kws_engine.dart';

/// Example: Using KwsEngine instead of text-based interruption detection
///
/// ADVANTAGES over current text-based approach:
/// - Faster detection (no ASR processing delay)
/// - More reliable (dedicated model for specific words)
/// - Lower latency (~50-100ms faster)
///
/// REQUIREMENTS:
/// 1. Download KWS model from:
///    https://github.com/k2-fsa/sherpa-onnx/releases/tag/kws-models
///
/// 2. Add to assets/models/kws/:
///    - encoder-epoch-12-avg-2-chunk-16-left-64.onnx
///    - decoder-epoch-12-avg-2-chunk-16-left-64.onnx
///    - joiner-epoch-12-avg-2-chunk-16-left-64.onnx
///    - tokens.txt
///
/// 3. Update pubspec.yaml:
///    assets:
///      - assets/models/kws/

class KwsInterruptionExample {
  KwsEngine? _kwsEngine;

  /// Initialize the keyword spotter
  Future<void> initialize() async {
    _kwsEngine = await KwsEngine.create(
      modelPath: 'assets/models/kws',
      encoderFile: 'encoder-epoch-12-avg-2-chunk-16-left-64.onnx',
      decoderFile: 'decoder-epoch-12-avg-2-chunk-16-left-64.onnx',
      joinerFile: 'joiner-epoch-12-avg-2-chunk-16-left-64.onnx',
      tokensFile: 'tokens.txt',
      keywords: [
        'stop',
        'pause',
        'wait',
        'cancel',
        'hold on',
      ],
      keywordsThreshold:
          0.25, // Lower = more sensitive, higher = less false positives
    );
  }

  /// Process audio samples and check for interruption keywords
  /// Call this in your audio processing loop (same place as VAD/ASR)
  String? checkForInterruption(List<double> audioSamples) {
    if (_kwsEngine == null) return null;

    // Returns detected keyword or null
    return _kwsEngine!.update(samples: audioSamples);
  }

  /// Reset the keyword spotter
  void reset() {
    _kwsEngine?.reset();
  }

  /// Clean up resources
  void dispose() {
    _kwsEngine?.dispose();
  }
}

/// HOW TO INTEGRATE INTO CONTROLLER:
///
/// In controller.dart _onAudioData method, REPLACE this text-based check:
///
/// ```dart
/// // Voice interruption detection
/// if (_voiceInterruptionEnabled && _partial.isNotEmpty) {
///   final lowerText = _partial.toLowerCase();
///   final foundKeyword = interruptionKeywords.firstWhere(
///     (keyword) => lowerText.contains(keyword),
///     orElse: () => '',
///   );
///   if (foundKeyword.isNotEmpty) {
///     _handleInterruption(foundKeyword);
///     return;
///   }
/// }
/// ```
///
/// WITH this KWS-based check:
///
/// ```dart
/// // Voice interruption detection using KWS (faster, more reliable)
/// if (_voiceInterruptionEnabled && _kwsEngine != null) {
///   final detectedKeyword = _kwsEngine!.update(samples: samples);
///   if (detectedKeyword != null && detectedKeyword.isNotEmpty) {
///     _handleInterruption(detectedKeyword);
///     return;
///   }
/// }
/// ```
///
/// This way, interruption happens BEFORE ASR transcription, making it faster!
