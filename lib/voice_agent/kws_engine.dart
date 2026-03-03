import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart';

import 'asset_utils.dart';

/// Keyword Spotting Engine using Sherpa-ONNX
/// Detects specific keywords directly from audio (faster than ASR-based detection)
class KwsEngine {
  KwsEngine._(this._kws, this._stream);

  final KeywordSpotter _kws;
  final OnlineStream _stream;

  /// Creates a keyword spotting engine
  ///
  /// You'll need to download a KWS model from:
  /// https://github.com/k2-fsa/sherpa-onnx/releases/tag/kws-models
  ///
  /// Example models:
  /// - sherpa-onnx-kws-zipformer-wenetspeech-3.3M-2024-01-01 (Chinese)
  /// - sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01 (English)
  ///
  /// Parameters:
  /// - modelPath: Asset directory containing the model files
  /// - encoderFile: Encoder ONNX file name
  /// - decoderFile: Decoder ONNX file name
  /// - joinerFile: Joiner ONNX file name
  /// - tokensFile: Tokens file name
  /// - keywords: List of keywords to detect (e.g., ['stop', 'pause', 'wait'])
  /// - keywordsThreshold: Detection threshold (0.25 = more sensitive, 0.5 = less sensitive)
  static Future<KwsEngine> create({
    required String modelPath,
    required String encoderFile,
    required String decoderFile,
    required String joinerFile,
    required String tokensFile,
    required List<String> keywords,
    int maxActivePaths = 4,
    int numTrailingBlanks = 1,
    double keywordsScore = 1.0,
    double keywordsThreshold = 0.25,
  }) async {
    // Copy model files from assets
    final encoderPath = await copyAssetFile('$modelPath/$encoderFile');
    final decoderPath = await copyAssetFile('$modelPath/$decoderFile');
    final joinerPath = await copyAssetFile('$modelPath/$joinerFile');
    final tokens = await copyAssetFile('$modelPath/$tokensFile');

    final config = KeywordSpotterConfig(
      model: OnlineModelConfig(
        transducer: OnlineTransducerModelConfig(
          encoder: encoderPath,
          decoder: decoderPath,
          joiner: joinerPath,
        ),
        tokens: tokens,
        modelType: 'zipformer2',
      ),
      maxActivePaths: maxActivePaths,
      numTrailingBlanks: numTrailingBlanks,
      keywordsScore: keywordsScore,
      keywordsThreshold: keywordsThreshold,
      keywordsBuf: keywords.join('\n'), // One keyword per line
      keywordsBufSize: keywords.join('\n').length,
    );

    final kws = KeywordSpotter(config);
    final stream = kws.createStream(keywords: keywords.join('\n'));

    return KwsEngine._(kws, stream);
  }

  /// Process audio samples and check for keyword detection
  /// Returns the detected keyword or null
  String? update({required List<double> samples}) {
    _stream.acceptWaveform(
      samples: Float32List.fromList(samples),
      sampleRate: 16000,
    );

    int readyCount = 0;
    while (_kws.isReady(_stream)) {
      readyCount++;
      _kws.decode(_stream);
    }

    if (readyCount > 0) {
      print('KWS Engine: Decoded $readyCount frames');
    }

    final result = _kws.getResult(_stream);
    if (result.keyword.isNotEmpty) {
      print('KWS Engine: ✅ DETECTED KEYWORD: "${result.keyword}"');
      return result.keyword; // Returns the detected keyword string
    }

    return null;
  }

  void reset() {
    _kws.reset(_stream);
  }

  void dispose() {
    _stream.free();
    _kws.free();
  }
}
