import 'dart:math' as math;
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';

class BytesAudioSource extends StreamAudioSource {
  BytesAudioSource(this._bytes) : super(tag: 'tts-bytes');
  final Uint8List _bytes;

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final s = start ?? 0;
    final e = end ?? _bytes.lengthInBytes;
    return StreamAudioResponse(
      sourceLength: _bytes.lengthInBytes,
      contentLength: e - s,
      offset: s,
      stream: Stream.value(_bytes.sublist(s, e)),
      contentType: 'audio/wav',
    );
  }
}

Float32List pcm16BytesToFloat32(Uint8List bytes) {
  final sampleCount = bytes.length ~/ 2;
  final out = Float32List(sampleCount);
  final bd = ByteData.sublistView(bytes);
  for (var i = 0; i < sampleCount; i++) {
    final val = bd.getInt16(i * 2, Endian.little);
    out[i] = val / 32768.0;
  }
  return out;
}

double rms(Float32List samples) {
  if (samples.isEmpty) return 0.0;
  var sum = 0.0;
  for (final s in samples) {
    sum += s * s;
  }
  return math.sqrt(sum / samples.length);
}
