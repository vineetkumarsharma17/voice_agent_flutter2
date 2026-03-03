enum SupportedLanguage {
  enUS,
  esMX,
  frCA,
}

class AsrModelFiles {
  const AsrModelFiles({
    required this.assetDir,
    required this.encoder,
    required this.decoder,
    required this.joiner,
    required this.tokens,
    required this.modelType,
  });

  final String assetDir;
  final String encoder;
  final String decoder;
  final String joiner;
  final String tokens;
  final String modelType;
}

class IntentModelFiles {
  const IntentModelFiles({
    required this.assetDir,
    required this.modelFile,
    required this.vocabFile,
    required this.labelsFile,
    this.maxLen = 64,
    this.doLowerCase = true,
  });

  final String assetDir;
  final String modelFile;
  final String vocabFile;
  final String labelsFile;
  final int maxLen;
  final bool doLowerCase;
}

class SlotModelFiles {
  const SlotModelFiles({
    required this.assetDir,
    required this.modelFile,
    required this.vocabFile,
    required this.labelsFile,
    this.maxLen = 64,
    this.doLowerCase = true,
  });

  final String assetDir;
  final String modelFile;
  final String vocabFile;
  final String labelsFile;
  final int maxLen;
  final bool doLowerCase;
}

class ResponseModelFiles {
  const ResponseModelFiles({
    required this.assetDir,
    required this.modelFile,
    required this.vocabFile,
    required this.responsesFile,
    this.maxLen = 64,
    this.doLowerCase = true,
  });

  final String assetDir;
  final String modelFile;
  final String vocabFile;
  final String responsesFile;
  final int maxLen;
  final bool doLowerCase;
}

class LanguageProfile {
  const LanguageProfile({
    required this.language,
    required this.displayName,
    required this.localeTag,
    required this.asr,
    required this.intent,
    required this.slots,
    required this.ttsSpeakerId,
    required this.ttsSpeakerName,
    required this.ttsLexicon,
  });

  final SupportedLanguage language;
  final String displayName;
  final String localeTag;
  final AsrModelFiles asr;
  final IntentModelFiles intent;
  final SlotModelFiles slots;
  final int ttsSpeakerId;
  final String ttsSpeakerName;
  final String ttsLexicon;
}

class ModelRegistry {
  static const String vadModelAsset = 'assets/models/vad/silero_vad.onnx';

  static const String ttsAssetDir = 'assets/models/tts/piper-lessac';
  static const String ttsModelFile = 'en_US-lessac-medium.onnx';
  static const String ttsTokensFile = 'tokens.txt';
  static const String ttsEspeakDataDir = 'espeak-ng-data';

  static const AsrModelFiles enStreaming = AsrModelFiles(
    assetDir: 'assets/models/asr/en',
    encoder: 'encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx',
    decoder: 'decoder-epoch-99-avg-1-chunk-16-left-128.onnx',
    joiner: 'joiner-epoch-99-avg-1-chunk-16-left-128.onnx',
    tokens: 'tokens.txt',
    modelType: 'zipformer2',
  );

  static const AsrModelFiles frStreaming = AsrModelFiles(
    assetDir: 'assets/models/asr/fr',
    encoder: 'encoder-epoch-29-avg-9-with-averaged-model.int8.onnx',
    decoder: 'decoder-epoch-29-avg-9-with-averaged-model.onnx',
    joiner: 'joiner-epoch-29-avg-9-with-averaged-model.onnx',
    tokens: 'tokens.txt',
    modelType: 'zipformer',
  );

  static const AsrModelFiles esStreaming = AsrModelFiles(
    assetDir: 'assets/models/asr/es',
    encoder: 'encoder.onnx',
    decoder: 'decoder.onnx',
    joiner: 'joiner.onnx',
    tokens: 'tokens.txt',
    modelType: 'zipformer2',
  );

  static const IntentModelFiles intentEn = IntentModelFiles(
    assetDir: 'assets/models/intent/en',
    modelFile: 'model.tflite',
    vocabFile: 'vocab.txt',
    labelsFile: 'labels.txt',
    maxLen: 64,
    doLowerCase: true,
  );

  static const IntentModelFiles intentEs = IntentModelFiles(
    assetDir: 'assets/models/intent/es',
    modelFile: 'model.tflite',
    vocabFile: 'vocab.txt',
    labelsFile: 'labels.txt',
    maxLen: 64,
    doLowerCase: true,
  );

  static const IntentModelFiles intentFr = IntentModelFiles(
    assetDir: 'assets/models/intent/fr',
    modelFile: 'model.tflite',
    vocabFile: 'vocab.txt',
    labelsFile: 'labels.txt',
    maxLen: 64,
    doLowerCase: true,
  );

  static const SlotModelFiles slotsEn = SlotModelFiles(
    assetDir: 'assets/models/slots/en',
    modelFile: 'model.tflite',
    vocabFile: 'vocab.txt',
    labelsFile: 'labels.txt',
    maxLen: 64,
    doLowerCase: true,
  );

  static const SlotModelFiles slotsEs = SlotModelFiles(
    assetDir: 'assets/models/slots/es',
    modelFile: 'model.tflite',
    vocabFile: 'vocab.txt',
    labelsFile: 'labels.txt',
    maxLen: 64,
    doLowerCase: true,
  );

  static const SlotModelFiles slotsFr = SlotModelFiles(
    assetDir: 'assets/models/slots/fr',
    modelFile: 'model.tflite',
    vocabFile: 'vocab.txt',
    labelsFile: 'labels.txt',
    maxLen: 64,
    doLowerCase: true,
  );

  static const ResponseModelFiles responseModel = ResponseModelFiles(
    assetDir: 'assets/models/response',
    modelFile: 'encoder.tflite',
    vocabFile: 'vocab.txt',
    responsesFile: 'responses.json',
    maxLen: 64,
    doLowerCase: true,
  );

  static const Map<SupportedLanguage, LanguageProfile> languages = {
    SupportedLanguage.enUS: LanguageProfile(
      language: SupportedLanguage.enUS,
      displayName: 'English (US)',
      localeTag: 'en-US',
      asr: enStreaming,
      intent: intentEn,
      slots: slotsEn,
      ttsSpeakerId: 0,
      ttsSpeakerName: 'piper-en_US-lessac-medium',
      ttsLexicon: '',
    ),
    SupportedLanguage.esMX: LanguageProfile(
      language: SupportedLanguage.esMX,
      displayName: 'Spanish (MX)',
      localeTag: 'es-MX',
      asr: esStreaming,
      intent: intentEs,
      slots: slotsEs,
      ttsSpeakerId: 0,
      ttsSpeakerName: 'piper-en_US-lessac-medium',
      ttsLexicon: '',
    ),
    SupportedLanguage.frCA: LanguageProfile(
      language: SupportedLanguage.frCA,
      displayName: 'French (CA)',
      localeTag: 'fr-CA',
      asr: frStreaming,
      intent: intentFr,
      slots: slotsFr,
      ttsSpeakerId: 0,
      ttsSpeakerName: 'piper-en_US-lessac-medium',
      ttsLexicon: '',
    ),
  };
}
