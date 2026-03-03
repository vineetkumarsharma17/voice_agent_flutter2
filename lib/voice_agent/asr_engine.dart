import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart';

import 'asset_utils.dart';
import 'model_registry.dart';

class AsrEngine {
  AsrEngine._(this._recognizer, this._stream);

  final OnlineRecognizer _recognizer;
  final OnlineStream _stream;

  static Future<AsrEngine> create(AsrModelFiles model) async {
    final encoder = await copyAssetFile('${model.assetDir}/${model.encoder}');
    final decoder = await copyAssetFile('${model.assetDir}/${model.decoder}');
    final joiner = await copyAssetFile('${model.assetDir}/${model.joiner}');
    final tokens = await copyAssetFile('${model.assetDir}/${model.tokens}');

    final config = OnlineRecognizerConfig(
      model: OnlineModelConfig(
        transducer: OnlineTransducerModelConfig(
          encoder: encoder,
          decoder: decoder,
          joiner: joiner,
        ),
        tokens: tokens,
        modelType: model.modelType,
      ),
      decodingMethod: 'greedy_search',
      maxActivePaths: 4,
      enableEndpoint: true,
      ruleFsts: '',
    );

    final recognizer = OnlineRecognizer(config);
    final stream = recognizer.createStream();
    return AsrEngine._(recognizer, stream);
  }

  void acceptSamples(List<double> samples, int sampleRate) {
    _stream.acceptWaveform(samples: Float32List.fromList(samples), sampleRate: sampleRate);
  }

  String decodeAndGetPartial() {
    while (_recognizer.isReady(_stream)) {
      _recognizer.decode(_stream);
    }
    return _recognizer.getResult(_stream).text;
  }

  bool isEndpoint() {
    return _recognizer.isEndpoint(_stream);
  }

  String finalResult() {
    return _recognizer.getResult(_stream).text;
  }

  void reset() {
    _recognizer.reset(_stream);
  }

  void dispose() {
    _recognizer.free();
  }
}
