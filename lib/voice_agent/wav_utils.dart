import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

void writeWavFile(String path, List<double> samples, int sampleRate) {
  const numChannels = 1;
  const bitsPerSample = 16;
  final bytesPerSample = bitsPerSample ~/ 8;
  final dataSize = samples.length * bytesPerSample;
  final fileSize = 36 + dataSize;

  final header = BytesBuilder();
  header.add(_ascii('RIFF'));
  header.add(_int32le(fileSize));
  header.add(_ascii('WAVE'));
  header.add(_ascii('fmt '));
  header.add(_int32le(16));
  header.add(_int16le(1));
  header.add(_int16le(numChannels));
  header.add(_int32le(sampleRate));
  header.add(_int32le(sampleRate * numChannels * bytesPerSample));
  header.add(_int16le(numChannels * bytesPerSample));
  header.add(_int16le(bitsPerSample));
  header.add(_ascii('data'));
  header.add(_int32le(dataSize));

  final pcm = BytesBuilder();
  for (final sample in samples) {
    final clamped = math.max(-1.0, math.min(1.0, sample));
    final value = (clamped * 32767).round();
    pcm.add(_int16le(value));
  }

  final file = File(path);
  file.writeAsBytesSync(header.toBytes() + pcm.toBytes(), flush: true);
}

/// Builds a WAV [Uint8List] entirely in memory — no disk I/O.
Uint8List wavBytesFromSamples(List<double> samples, int sampleRate) {
  const numChannels = 1;
  const bitsPerSample = 16;
  final bytesPerSample = bitsPerSample ~/ 8;
  final dataSize = samples.length * bytesPerSample;
  final fileSize = 36 + dataSize;

  final header = BytesBuilder();
  header.add(_ascii('RIFF'));
  header.add(_int32le(fileSize));
  header.add(_ascii('WAVE'));
  header.add(_ascii('fmt '));
  header.add(_int32le(16));
  header.add(_int16le(1));
  header.add(_int16le(numChannels));
  header.add(_int32le(sampleRate));
  header.add(_int32le(sampleRate * numChannels * bytesPerSample));
  header.add(_int16le(numChannels * bytesPerSample));
  header.add(_int16le(bitsPerSample));
  header.add(_ascii('data'));
  header.add(_int32le(dataSize));

  final pcm = BytesBuilder();
  for (final sample in samples) {
    final clamped = math.max(-1.0, math.min(1.0, sample));
    final value = (clamped * 32767).round();
    pcm.add(_int16le(value));
  }

  return Uint8List.fromList(header.toBytes() + pcm.toBytes());
}

List<int> _ascii(String text) => text.codeUnits;

List<int> _int16le(int value) {
  final data = ByteData(2)..setInt16(0, value, Endian.little);
  return data.buffer.asUint8List();
}

List<int> _int32le(int value) {
  final data = ByteData(4)..setInt32(0, value, Endian.little);
  return data.buffer.asUint8List();
}
