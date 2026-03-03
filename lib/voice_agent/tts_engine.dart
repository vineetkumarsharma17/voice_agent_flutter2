import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart'
    show
        OfflineTts,
        OfflineTtsConfig,
        OfflineTtsModelConfig,
        OfflineTtsVitsModelConfig,
        initBindings;

import 'asset_utils.dart';
import 'model_registry.dart';
import 'wav_utils.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  Public data class — a single chunk of synthesised audio
// ═══════════════════════════════════════════════════════════════════════════

/// A single chunk of synthesised audio returned by [TtsEngine.synthesizeStream].
class TtsAudioChunk {
  /// Raw PCM samples, float32, mono, range [-1, 1].
  final Float32List samples;

  /// Sample rate of the model (e.g. 22 050 Hz).
  final int sampleRate;

  /// Position of this chunk within the current request.
  final int chunkIndex;

  /// `true` when this is the last chunk for the current request.
  final bool isLast;

  const TtsAudioChunk({
    required this.samples,
    required this.sampleRate,
    required this.chunkIndex,
    this.isLast = false,
  });

  /// Duration represented by this chunk in milliseconds.
  int get durationMs =>
      sampleRate > 0 ? (samples.length * 1000 ~/ sampleRate) : 0;
}

// ═══════════════════════════════════════════════════════════════════════════
//  Private isolate message types
// ═══════════════════════════════════════════════════════════════════════════

class _InitMsg {
  final String model;
  final String tokens;
  final String dataDir;
  final int numThreads;
  final SendPort replyTo;
  const _InitMsg({
    required this.model,
    required this.tokens,
    required this.dataDir,
    required this.numThreads,
    required this.replyTo,
  });
}

class _SynthMsg {
  final String text;
  final int speakerId;
  final double speed;
  final SendPort replyTo;
  const _SynthMsg({
    required this.text,
    required this.speakerId,
    required this.speed,
    required this.replyTo,
  });
}

class _StreamMsg {
  final String text;
  final int speakerId;
  final double speed;
  final int requestId;
  final SendPort replyTo;
  const _StreamMsg({
    required this.text,
    required this.speakerId,
    required this.speed,
    required this.requestId,
    required this.replyTo,
  });
}

class _AudioResult {
  final Float32List samples;
  final int sampleRate;
  const _AudioResult({required this.samples, required this.sampleRate});
}

class _StreamChunkResult {
  final Float32List samples;
  final int sampleRate;
  final int chunkIndex;
  final bool isLast;
  final int requestId;
  const _StreamChunkResult({
    required this.samples,
    required this.sampleRate,
    required this.chunkIndex,
    required this.isLast,
    required this.requestId,
  });
}

class _ErrorResult {
  final String message;
  const _ErrorResult(this.message);
}

// ═══════════════════════════════════════════════════════════════════════════
//  Sentence splitter — runs inside the worker isolate
// ═══════════════════════════════════════════════════════════════════════════

const int _maxCharsPerChunk = 200;
final RegExp _sentenceEnd = RegExp(r'(?<=[.!?。！？])\s+|\n+');
final RegExp _clauseEnd = RegExp(r'(?<=[,;:，；：—–\-])\s+');

List<String> _splitSentences(String text) {
  final raw = text.split(_sentenceEnd).where((s) => s.trim().isNotEmpty);
  final result = <String>[];

  for (final sentence in raw) {
    if (sentence.length <= _maxCharsPerChunk) {
      result.add(sentence.trim());
      continue;
    }

    // Clause-level split for long sentences.
    final clauses =
        sentence.split(_clauseEnd).where((s) => s.trim().isNotEmpty);
    final buffer = StringBuffer();

    for (final clause in clauses) {
      if (buffer.length + clause.length > _maxCharsPerChunk &&
          buffer.isNotEmpty) {
        result.add(buffer.toString().trim());
        buffer.clear();
      }

      // Word-boundary fallback for oversized clauses.
      if (clause.length > _maxCharsPerChunk) {
        if (buffer.isNotEmpty) {
          result.add(buffer.toString().trim());
          buffer.clear();
        }
        final words = clause.split(RegExp(r'\s+'));
        final wordBuf = StringBuffer();
        for (final word in words) {
          if (wordBuf.length + word.length + 1 > _maxCharsPerChunk &&
              wordBuf.isNotEmpty) {
            result.add(wordBuf.toString().trim());
            wordBuf.clear();
          }
          if (wordBuf.isNotEmpty) wordBuf.write(' ');
          wordBuf.write(word);
        }
        if (wordBuf.isNotEmpty) buffer.write(wordBuf);
        continue;
      }

      if (buffer.isNotEmpty) buffer.write(' ');
      buffer.write(clause);
    }

    if (buffer.isNotEmpty) result.add(buffer.toString().trim());
  }

  return result;
}

// ═══════════════════════════════════════════════════════════════════════════
//  TtsEngine
// ═══════════════════════════════════════════════════════════════════════════

class TtsEngine {
  static TtsEngine? _instance;
  static Completer<TtsEngine>? _initCompleter;

  static TtsEngine get instance {
    if (_instance == null) {
      throw StateError('TtsEngine not initialized. Call init() first.');
    }
    return _instance!;
  }

  TtsEngine._(this._isolate, this._sendPort);

  final Isolate _isolate;
  final SendPort _sendPort;
  bool _isDisposed = false;

  /// Monotonically increasing id — lets the main isolate discard chunks from
  /// a previous [synthesizeStream] call after [stopStream] is called.
  int _requestId = 0;
  int? _activeRequestId;

  // ── Init ──────────────────────────────────────────────────────────────────

  static Future<TtsEngine> init({int numThreads = 4}) async {
    if (_instance != null) return _instance!;

    // Guard against concurrent init() calls.
    if (_initCompleter != null) return _initCompleter!.future;
    _initCompleter = Completer<TtsEngine>();

    try {
      final watch = Stopwatch()..start();
      final modelDir = ModelRegistry.ttsAssetDir;

      // Copy assets in parallel — no-ops after the first run.
      late final String model, tokens;
      await Future.wait([
        copyAssetFile('$modelDir/${ModelRegistry.ttsModelFile}')
            .then((v) => model = v),
        copyAssetFile('$modelDir/${ModelRegistry.ttsTokensFile}')
            .then((v) => tokens = v),
        copyAssetDirectory('$modelDir/${ModelRegistry.ttsEspeakDataDir}/'),
      ]);
      final dataDir = await localDirForAssetPrefix(
          '$modelDir/${ModelRegistry.ttsEspeakDataDir}');

      debugPrint('[TTS] Assets ready in ${watch.elapsedMilliseconds} ms');

      // Spawn dedicated isolate.
      final handshake = ReceivePort();
      final isolate = await Isolate.spawn(
        _ttsWorker,
        handshake.sendPort,
        debugName: 'tts-worker',
      );
      final sendPort = await handshake.first as SendPort;
      handshake.close();

      _instance = TtsEngine._(isolate, sendPort);

      // Initialise native model inside isolate.
      final initReply = ReceivePort();
      sendPort.send(_InitMsg(
        model: model,
        tokens: tokens,
        dataDir: dataDir,
        numThreads: numThreads,
        replyTo: initReply.sendPort,
      ));
      final initResult = await initReply.first;
      initReply.close();

      if (initResult != true) {
        _instance = null;
        throw Exception('TTS isolate init failed: $initResult');
      }

      // Pre-warm: first ONNX inference is always slow.
      debugPrint('[TTS] Pre-warming engine…');
      await _instance!._preWarm();

      watch.stop();
      debugPrint('[TTS] Ready in ${watch.elapsedMilliseconds} ms');

      _initCompleter!.complete(_instance!);
      return _instance!;
    } catch (e, st) {
      _initCompleter!.completeError(e, st);
      _initCompleter = null;
      rethrow;
    }
  }

  // ── Isolate worker ────────────────────────────────────────────────────────

  static void _ttsWorker(SendPort mainPort) {
    initBindings();

    final port = ReceivePort();
    mainPort.send(port.sendPort);

    OfflineTts? tts;
    int? modelSampleRate;

    port.listen((msg) {
      // ── Init ────────────────────────────────────────────────────────
      if (msg is _InitMsg) {
        try {
          final config = OfflineTtsConfig(
            model: OfflineTtsModelConfig(
              vits: OfflineTtsVitsModelConfig(
                model: msg.model,
                tokens: msg.tokens,
                dataDir: msg.dataDir,
                noiseScale: 0.667,
                noiseScaleW: 0.8,
                lengthScale: 1.0,
              ),
              numThreads: msg.numThreads,
              debug: false,
              provider: 'cpu',
            ),
            maxNumSenetences: 1,
          );
          tts = OfflineTts(config);
          try {
            modelSampleRate = tts!.sampleRate;
          } catch (_) {
            modelSampleRate = null;
          }
          msg.replyTo.send(true);
        } catch (e) {
          msg.replyTo.send(e.toString());
        }
        return;
      }

      // ── Single-shot synthesis ────────────────────────────────────────
      if (msg is _SynthMsg) {
        if (tts == null) {
          msg.replyTo.send(_ErrorResult('TTS not initialised'));
          return;
        }
        try {
          final audio = tts!.generate(
            text: msg.text,
            sid: msg.speakerId,
            speed: msg.speed,
          );
          msg.replyTo.send(_AudioResult(
              samples: audio.samples, sampleRate: audio.sampleRate));
        } catch (e) {
          msg.replyTo.send(_ErrorResult(e.toString()));
        }
        return;
      }

      // ── Streaming synthesis ──────────────────────────────────────────
      if (msg is _StreamMsg) {
        if (tts == null) {
          msg.replyTo.send(_ErrorResult('TTS not initialised'));
          return;
        }
        final sentences = _splitSentences(msg.text);
        if (sentences.isEmpty) {
          msg.replyTo.send(_StreamChunkResult(
            samples: Float32List(0),
            sampleRate: modelSampleRate ?? 22050,
            chunkIndex: 0,
            isLast: true,
            requestId: msg.requestId,
          ));
          return;
        }
        for (int i = 0; i < sentences.length; i++) {
          try {
            final audio = tts!.generate(
              text: sentences[i],
              sid: msg.speakerId,
              speed: msg.speed,
            );
            msg.replyTo.send(_StreamChunkResult(
              samples: audio.samples,
              sampleRate: audio.sampleRate,
              chunkIndex: i,
              isLast: i == sentences.length - 1,
              requestId: msg.requestId,
            ));
          } catch (e) {
            msg.replyTo.send(_ErrorResult(e.toString()));
            return;
          }
        }
        return;
      }

      // ── Dispose ──────────────────────────────────────────────────────
      if (msg == 'dispose') {
        tts?.free();
        tts = null;
        port.close();
      }
    });
  }

  // ── Internal helpers ──────────────────────────────────────────────────────

  Future<void> _preWarm() async {
    final profile = ModelRegistry.languages.values.first;
    // Use a real word so espeak-ng runs its full phonemisation pipeline.
    await synthesizeToBytes(text: 'hello', language: profile);
  }

  // ── Public API ────────────────────────────────────────────────────────────

  /// Returns a [Stream] of [TtsAudioChunk]s (raw Float32 PCM).
  ///
  /// The text is split into sentences internally. Each sentence is synthesised
  /// in the worker isolate and emitted as soon as it is ready — so the caller
  /// can start playback of chunk 0 while chunk 1 is still being generated.
  ///
  /// Call [stopStream] to cancel an in-progress stream cleanly.
  Stream<TtsAudioChunk> synthesizeStream({
    required String text,
    required LanguageProfile language,
    double speed = 1.0,
  }) {
    _throwIfDisposed();

    final reqId = ++_requestId;
    _activeRequestId = reqId;

    late final StreamController<TtsAudioChunk> controller;
    ReceivePort? replyPort;

    controller = StreamController<TtsAudioChunk>(
      onListen: () {
        replyPort = ReceivePort();
        _sendPort.send(_StreamMsg(
          text: text,
          speakerId: language.ttsSpeakerId,
          speed: speed,
          requestId: reqId,
          replyTo: replyPort!.sendPort,
        ));

        replyPort!.listen((msg) {
          // Stale request — discard silently.
          if (_activeRequestId != reqId) {
            replyPort?.close();
            if (!controller.isClosed) controller.close();
            return;
          }

          if (msg is _StreamChunkResult) {
            if (msg.requestId != reqId) return;
            controller.add(TtsAudioChunk(
              samples: msg.samples,
              sampleRate: msg.sampleRate,
              chunkIndex: msg.chunkIndex,
              isLast: msg.isLast,
            ));
            if (msg.isLast) {
              _activeRequestId = null;
              replyPort?.close();
              controller.close();
            }
          } else if (msg is _ErrorResult) {
            _activeRequestId = null;
            replyPort?.close();
            controller.addError(Exception(msg.message));
            controller.close();
          }
        });
      },
      onCancel: () {
        _activeRequestId = null;
        replyPort?.close();
      },
    );

    return controller.stream;
  }

  /// Cancel any in-progress [synthesizeStream] cleanly (no error emitted).
  void stopStream() {
    _activeRequestId = null;
  }

  /// Synthesises [text] and returns a complete WAV-encoded [Uint8List].
  Future<Uint8List> synthesizeToBytes({
    required String text,
    required LanguageProfile language,
    double speed = 1.0,
  }) async {
    _throwIfDisposed();

    final reply = ReceivePort();
    _sendPort.send(_SynthMsg(
      text: text,
      speakerId: language.ttsSpeakerId,
      speed: speed,
      replyTo: reply.sendPort,
    ));

    final result = await reply.first;
    reply.close();

    if (result is _ErrorResult) throw Exception(result.message);

    final audio = result as _AudioResult;
    return wavBytesFromSamples(audio.samples, audio.sampleRate);
  }

  /// Synthesises [text] streaming sentence-by-sentence.
  /// Yields WAV [Uint8List] per sentence — kept for [VoiceAgentController] compat.
  Stream<Uint8List> synthesizeStreaming({
    required String text,
    required LanguageProfile language,
  }) {
    // Delegate to the new PCM stream and convert each chunk on the fly.
    return synthesizeStream(text: text, language: language).map(
      (chunk) => wavBytesFromSamples(chunk.samples, chunk.sampleRate),
    );
  }

  /// Synthesises [text] and writes a WAV file; returns its path.
  Future<String> synthesizeToWav({
    required String text,
    required LanguageProfile language,
  }) async {
    final bytes = await synthesizeToBytes(text: text, language: language);
    final tempDir = await getTemporaryDirectory();
    final wavPath = p.join(
      tempDir.path,
      'tts_${DateTime.now().millisecondsSinceEpoch}.wav',
    );
    await File(wavPath).writeAsBytes(bytes, flush: true);
    return wavPath;
  }

  void _throwIfDisposed() {
    if (_isDisposed) throw StateError('TtsEngine has been disposed');
  }

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _activeRequestId = null;
    _sendPort.send('dispose');
    // Give the worker time to finish any in-progress generate() + free().
    Future.delayed(const Duration(seconds: 2), () {
      _isolate.kill(priority: Isolate.beforeNextEvent);
    });
    _instance = null;
    _initCompleter = null;
  }
}
