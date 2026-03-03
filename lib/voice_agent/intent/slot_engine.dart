import 'dart:io';
import 'dart:math' as math;

import 'package:tflite_flutter/tflite_flutter.dart';

import '../asset_utils.dart';
import '../model_registry.dart';
import 'tokenizer.dart';

class SlotEngine {
  SlotEngine._(this._models, {required this.numThreads});

  final Map<SupportedLanguage, _SlotModel> _models;
  final int numThreads;

  static Future<SlotEngine> create({int numThreads = 2}) async {
    return SlotEngine._(<SupportedLanguage, _SlotModel>{}, numThreads: numThreads);
  }

  Future<SlotResult> tag({
    required String text,
    required LanguageProfile profile,
  }) async {
    final model = await _loadModel(profile);
    return model.tag(text);
  }

  Future<_SlotModel> _loadModel(LanguageProfile profile) async {
    final existing = _models[profile.language];
    if (existing != null) {
      return existing;
    }

    final files = profile.slots;
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

    final slotModel = _SlotModel(
      interpreter: interpreter,
      tokenizer: tokenizer,
      labels: labels,
      maxLen: maxLen,
    );

    _models[profile.language] = slotModel;
    return slotModel;
  }

  void dispose() {
    for (final model in _models.values) {
      model.interpreter.close();
    }
    _models.clear();
  }
}

class _SlotModel {
  _SlotModel({
    required this.interpreter,
    required this.tokenizer,
    required this.labels,
    required this.maxLen,
  });

  final Interpreter interpreter;
  final WordPieceTokenizer tokenizer;
  final List<String> labels;
  final int maxLen;

  SlotResult tag(String text) {
    final tokenized = tokenizer.encode(text, maxLen);
    final inputIds = [tokenized.inputIds];
    final attentionMask = [tokenized.attentionMask];
    final tokenTypeIds = [tokenized.tokenTypeIds];

    final outputTensor = interpreter.getOutputTensor(0);
    final outputShape = outputTensor.shape;

    final seqLen = outputShape.length >= 2 ? outputShape[1] : maxLen;
    final numLabels = outputShape.isNotEmpty ? outputShape.last : labels.length;

    final output = [List.generate(seqLen, (_) => List<double>.filled(numLabels, 0.0))];

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
    final tags = <String>[];

    for (var i = 0; i < math.min(seqLen, tokenized.tokens.length); i++) {
      final scores = logits[i];
      var bestIdx = 0;
      var bestScore = scores[0];
      for (var j = 1; j < scores.length; j++) {
        if (scores[j] > bestScore) {
          bestScore = scores[j];
          bestIdx = j;
        }
      }
      tags.add(bestIdx < labels.length ? labels[bestIdx] : 'O');
    }

    final slots = _decodeSlots(tokenized.tokens, tags);
    return SlotResult(slots: slots, tags: tags);
  }

  Map<String, String> _decodeSlots(List<String> tokens, List<String> tags) {
    final slots = <String, String>{};
    String? currentSlot;
    final buffer = StringBuffer();

    void flush() {
      if (currentSlot == null || buffer.isEmpty) return;
      slots[currentSlot!] = buffer.toString().trim();
      buffer.clear();
      currentSlot = null;
    }

    for (var i = 0; i < math.min(tokens.length, tags.length); i++) {
      final token = tokens[i];
      final tag = tags[i];

      if (token == '[CLS]' || token == '[SEP]') {
        continue;
      }

      if (tag.startsWith('B-')) {
        flush();
        currentSlot = tag.substring(2);
        _appendToken(buffer, token);
      } else if (tag.startsWith('I-') && currentSlot == tag.substring(2)) {
        _appendToken(buffer, token);
      } else {
        flush();
      }
    }

    flush();
    return slots;
  }

  void _appendToken(StringBuffer buffer, String token) {
    if (token.startsWith('##')) {
      buffer.write(token.substring(2));
    } else {
      if (buffer.isNotEmpty) buffer.write(' ');
      buffer.write(token);
    }
  }
}

class SlotResult {
  const SlotResult({required this.slots, required this.tags});

  final Map<String, String> slots;
  final List<String> tags;
}
