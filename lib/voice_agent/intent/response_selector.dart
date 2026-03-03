import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:tflite_flutter/tflite_flutter.dart';

import '../asset_utils.dart';
import '../model_registry.dart';
import 'tokenizer.dart';

class ResponseSelector {
  ResponseSelector._(this._encoder, this._tokenizer, this._responses, this._maxLen);

  final _Encoder _encoder;
  final WordPieceTokenizer _tokenizer;
  final List<ResponseTemplate> _responses;
  final int _maxLen;

  static Future<ResponseSelector> create(ResponseModelFiles files) async {
    final modelPath = await copyAssetFile('${files.assetDir}/${files.modelFile}');
    final vocabPath = await copyAssetFile('${files.assetDir}/${files.vocabFile}');
    final responsesPath = await copyAssetFile('${files.assetDir}/${files.responsesFile}');

    final vocab = await File(vocabPath).readAsLines();
    final tokenizer = WordPieceTokenizer(vocab, doLowerCase: files.doLowerCase);

    final options = InterpreterOptions()..threads = 2;
    final interpreter = Interpreter.fromFile(File(modelPath), options: options);

    final inputTensor = interpreter.getInputTensor(0);
    final inputShape = inputTensor.shape;
    final maxLen = inputShape.isNotEmpty ? inputShape.last : files.maxLen;

    final encoder = _Encoder(interpreter: interpreter, maxLen: maxLen);

    final responsesJson = json.decode(await File(responsesPath).readAsString());
    final responses = (responsesJson as List)
        .map((entry) => ResponseTemplate.fromJson(entry as Map<String, dynamic>))
        .toList(growable: false);

    final selector = ResponseSelector._(encoder, tokenizer, responses, maxLen);
    await selector._ensureEmbeddings();
    return selector;
  }

  Future<ResponseTemplate?> select({
    required String query,
    required SupportedLanguage language,
    required String intent,
    required Map<String, String> slots,
  }) async {
    final candidates = _responses.where((response) {
      if (response.language != null && response.language != language) {
        return false;
      }
      if (response.intent != null && response.intent != intent) {
        return false;
      }
      if (!response.hasRequiredSlots(slots)) {
        return false;
      }
      return true;
    }).toList(growable: false);

    if (candidates.isEmpty) return null;

    final queryEmbedding = _encode(query);

    ResponseTemplate best = candidates.first;
    var bestScore = _cosine(queryEmbedding, candidates.first.embedding!);

    for (var i = 1; i < candidates.length; i++) {
      final score = _cosine(queryEmbedding, candidates[i].embedding!);
      if (score > bestScore) {
        best = candidates[i];
        bestScore = score;
      }
    }

    return best;
  }

  Future<void> _ensureEmbeddings() async {
    for (final response in _responses) {
      if (response.embedding != null) continue;
      response.embedding = _encode(response.text);
    }
  }

  List<double> _encode(String text) {
    final tokenized = _tokenizer.encode(text, _maxLen);
    final inputIds = [tokenized.inputIds];
    final attentionMask = [tokenized.attentionMask];
    final tokenTypeIds = [tokenized.tokenTypeIds];

    return _encoder.encode(
      inputIds: inputIds,
      attentionMask: attentionMask,
      tokenTypeIds: tokenTypeIds,
    );
  }

  double _cosine(List<double> a, List<double> b) {
    var dot = 0.0;
    var normA = 0.0;
    var normB = 0.0;
    final len = math.min(a.length, b.length);
    for (var i = 0; i < len; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    if (normA == 0 || normB == 0) return 0.0;
    return dot / (math.sqrt(normA) * math.sqrt(normB));
  }

  void dispose() {
    _encoder.interpreter.close();
  }
}

class _Encoder {
  _Encoder({required this.interpreter, required this.maxLen});

  final Interpreter interpreter;
  final int maxLen;

  List<double> encode({
    required List<List<int>> inputIds,
    required List<List<int>> attentionMask,
    required List<List<int>> tokenTypeIds,
  }) {
    final outputTensor = interpreter.getOutputTensor(0);
    final outputShape = outputTensor.shape;

    final inputCount = interpreter.getInputTensors().length;

    if (outputShape.length == 2) {
      final hidden = outputShape.last;
      final output = [List<double>.filled(hidden, 0.0)];
      if (inputCount >= 3) {
        interpreter.runForMultipleInputs(
          [inputIds, attentionMask, tokenTypeIds],
          {0: output},
        );
      } else {
        interpreter.run(inputIds, output);
      }
      return _normalize(output.first);
    }

    final seqLen = outputShape.length >= 2 ? outputShape[1] : maxLen;
    final hidden = outputShape.length >= 3 ? outputShape[2] : 256;
    final output = [
      List.generate(seqLen, (_) => List<double>.filled(hidden, 0.0))
    ];

    if (inputCount >= 3) {
      interpreter.runForMultipleInputs(
        [inputIds, attentionMask, tokenTypeIds],
        {0: output},
      );
    } else {
      interpreter.run(inputIds, output);
    }

    final embeddings = output.first;
    final pooled = List<double>.filled(hidden, 0.0);
    var count = 0.0;

    for (var i = 0; i < math.min(seqLen, attentionMask.first.length); i++) {
      if (attentionMask.first[i] == 0) continue;
      final token = embeddings[i];
      for (var j = 0; j < hidden; j++) {
        pooled[j] += token[j];
      }
      count += 1.0;
    }

    if (count > 0) {
      for (var j = 0; j < hidden; j++) {
        pooled[j] /= count;
      }
    }

    return _normalize(pooled);
  }

  List<double> _normalize(List<double> vector) {
    var norm = 0.0;
    for (final v in vector) {
      norm += v * v;
    }
    norm = math.sqrt(norm);
    if (norm == 0) return vector;
    return vector.map((v) => v / norm).toList(growable: false);
  }
}

class ResponseTemplate {
  ResponseTemplate({
    required this.id,
    required this.text,
    this.intent,
    this.language,
    this.requiredSlots = const [],
    this.embedding,
  });

  final String id;
  final String text;
  final String? intent;
  final SupportedLanguage? language;
  final List<String> requiredSlots;
  List<double>? embedding;

  bool hasRequiredSlots(Map<String, String> slots) {
    for (final slot in requiredSlots) {
      if (!slots.containsKey(slot)) return false;
    }
    return true;
  }

  String render(Map<String, String> slots) {
    var out = text;
    slots.forEach((key, value) {
      out = out.replaceAll('{$key}', value);
    });
    return out;
  }

  static ResponseTemplate fromJson(Map<String, dynamic> json) {
    final lang = json['language'] as String?;
    return ResponseTemplate(
      id: json['id'] as String,
      text: json['text'] as String,
      intent: json['intent'] as String?,
      language: _parseLanguage(lang),
      requiredSlots: (json['required_slots'] as List?)
              ?.map((e) => e.toString())
              .toList(growable: false) ??
          const [],
      embedding: (json['embedding'] as List?)
          ?.map((e) => (e as num).toDouble())
          .toList(growable: false),
    );
  }

  static SupportedLanguage? _parseLanguage(String? value) {
    switch (value) {
      case 'en-US':
        return SupportedLanguage.enUS;
      case 'es-MX':
        return SupportedLanguage.esMX;
      case 'fr-CA':
        return SupportedLanguage.frCA;
      default:
        return null;
    }
  }
}
