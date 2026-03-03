import 'dart:io';
import 'dart:math' as math;

import 'package:tflite_flutter/tflite_flutter.dart';

import '../asset_utils.dart';
import '../model_registry.dart';
import 'tokenizer.dart';

class IntentEngine {
  IntentEngine._(this._models, {required this.numThreads});

  final Map<SupportedLanguage, _IntentModel> _models;
  final int numThreads;

  static Future<IntentEngine> create({int numThreads = 2}) async {
    return IntentEngine._(<SupportedLanguage, _IntentModel>{}, numThreads: numThreads);
  }

  Future<IntentResult> classify({
    required String text,
    required LanguageProfile profile,
  }) async {
    final model = await _loadModel(profile);
    return model.classify(text);
  }

  Future<_IntentModel> _loadModel(LanguageProfile profile) async {
    final existing = _models[profile.language];
    if (existing != null) {
      return existing;
    }

    final files = profile.intent;
    final modelPath = await copyAssetFile('${files.assetDir}/${files.modelFile}');
    final vocabPath = await copyAssetFile('${files.assetDir}/${files.vocabFile}');
    final labelsPath = await copyAssetFile('${files.assetDir}/${files.labelsFile}');

    final vocab = await File(vocabPath).readAsLines();
    final labels = (await File(labelsPath).readAsLines())
        .where((line) => line.trim().isNotEmpty)
        .toList(growable: false);

    final options = InterpreterOptions()..threads = numThreads;
    final interpreter = Interpreter.fromFile(File(modelPath), options: options);

    final inputTensor = interpreter.getInputTensor(0);
    final inputShape = inputTensor.shape;
    final maxLen = inputShape.isNotEmpty ? inputShape.last : files.maxLen;

    final tokenizer = WordPieceTokenizer(vocab, doLowerCase: files.doLowerCase);

    final intentModel = _IntentModel(
      interpreter: interpreter,
      tokenizer: tokenizer,
      labels: labels,
      maxLen: maxLen,
    );

    _models[profile.language] = intentModel;
    return intentModel;
  }

  void dispose() {
    for (final model in _models.values) {
      model.interpreter.close();
    }
    _models.clear();
  }
}

class _IntentModel {
  _IntentModel({
    required this.interpreter,
    required this.tokenizer,
    required this.labels,
    required this.maxLen,
  });

  final Interpreter interpreter;
  final WordPieceTokenizer tokenizer;
  final List<String> labels;
  final int maxLen;

  IntentResult classify(String text) {
    final tokenized = tokenizer.encode(text, maxLen);
    final inputIds = [tokenized.inputIds];
    final attentionMask = [tokenized.attentionMask];
    final tokenTypeIds = [tokenized.tokenTypeIds];

    final outputTensor = interpreter.getOutputTensor(0);
    final outputShape = outputTensor.shape;
    final numLabels = outputShape.isNotEmpty ? outputShape.last : labels.length;
    final output = [List<double>.filled(numLabels, 0.0)];

    final inputCount = interpreter.getInputTensors().length;
    if (inputCount >= 3) {
      interpreter.runForMultipleInputs(
        [inputIds, attentionMask, tokenTypeIds],
        {0: output},
      );
    } else {
      interpreter.run(inputIds, output);
    }

    final logits = output.first;
    final probs = _softmax(logits);

    var bestIdx = 0;
    var bestScore = probs[0];
    final ranked = <IntentScore>[];
    for (var i = 0; i < probs.length; i++) {
      final label = i < labels.length ? labels[i] : 'label_$i';
      ranked.add(IntentScore(label: label, score: probs[i]));
      if (probs[i] > bestScore) {
        bestScore = probs[i];
        bestIdx = i;
      }
    }

    ranked.sort((a, b) => b.score.compareTo(a.score));
    final intent = bestIdx < labels.length ? labels[bestIdx] : 'fallback';
    return IntentResult(
      intent: intent,
      confidence: bestScore,
      probs: probs,
      ranked: ranked,
    );
  }

  List<double> _softmax(List<double> logits) {
    final maxLogit = logits.reduce(math.max);
    final exps = logits.map((v) => math.exp(v - maxLogit)).toList();
    final sum = exps.reduce((a, b) => a + b);
    return exps.map((v) => v / sum).toList(growable: false);
  }
}

class IntentResult {
  const IntentResult({
    required this.intent,
    required this.confidence,
    required this.probs,
    required this.ranked,
  });

  final String intent;
  final double confidence;
  final List<double> probs;
  final List<IntentScore> ranked;

  static const IntentResult fallback = IntentResult(
    intent: 'fallback',
    confidence: 0.0,
    probs: [],
    ranked: [],
  );
}

class IntentScore {
  const IntentScore({required this.label, required this.score});

  final String label;
  final double score;
}
