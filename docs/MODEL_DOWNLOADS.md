# Model Downloads

This app expects the following model files under `assets/models/`.

## ASR (Streaming Zipformer)

### English (US)
Place these in `assets/models/asr/en/` from the sherpa-onnx release:
- encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx
- decoder-epoch-99-avg-1-chunk-16-left-128.onnx
- joiner-epoch-99-avg-1-chunk-16-left-128.onnx
- tokens.txt

### French (CA)
Place these in `assets/models/asr/fr/` from the sherpa-onnx release.
This is a general French model; swap in a fr-CA specific model if you have one.
- encoder-epoch-29-avg-9-with-averaged-model.int8.onnx
- decoder-epoch-29-avg-9-with-averaged-model.onnx
- joiner-epoch-29-avg-9-with-averaged-model.onnx
- tokens.txt

### Spanish (MX)
Place these in `assets/models/asr/es/` from the BookBot release on HuggingFace.
This is a general Spanish model; swap in a es-MX specific model if you have one.
- encoder-epoch-80-avg-3-chunk-16-left-128.int8.onnx
- decoder-epoch-80-avg-3-chunk-16-left-128.int8.onnx
- joiner-epoch-80-avg-3-chunk-16-left-128.int8.onnx
- tokens.txt

## VAD
Place the Silero VAD ONNX model in `assets/models/vad/`:
- silero_vad.onnx

## TTS (Kokoro)
Place the Kokoro multi-lingual pack in `assets/models/tts/kokoro/`:
- model.onnx
- voices.bin
- tokens.txt
- espeak-ng-data/ (directory)
- lexicon-us-en.txt

Kokoro speaker IDs used by default:
- en-US: 3 (af_heart)
- es-MX: 28 (ef_dora)
- fr-CA: 30 (ff_siwis)

See the app-level README for links and notes on licensing.

## Intent Classification (Local)
Place lightweight BERT-style TFLite models and vocab/labels under:
- `assets/models/intent/en/`
- `assets/models/intent/es/`
- `assets/models/intent/fr/`

Each directory must contain:
- model.tflite
- vocab.txt
- labels.txt

The code expects a BERT-style classifier with `input_ids`, `attention_mask`,
and `token_type_ids` inputs (token_type_ids can be ignored by the model).
`labels.txt` should list one intent per line in the same order as the model output.

Default intents used by the response generator:
- greeting
- goodbye
- thanks
- help
- status
- repeat
- fallback

## Slot Tagging (Local)
Place token-classification TFLite models under:
- `assets/models/slots/en/`
- `assets/models/slots/es/`
- `assets/models/slots/fr/`

Each directory must contain:
- model.tflite
- vocab.txt
- labels.txt

Slot labels should be BIO format (e.g. B-NAME, I-NAME, O).

## Response Selection Model
Place the response encoder and response bank under `assets/models/response/`:
- encoder.tflite
- vocab.txt
- responses.json

`responses.json` schema (array of objects):
- id: string
- text: string
- intent: optional string
- language: optional (en-US, es-MX, fr-CA)
- required_slots: optional list of slot names
- embedding: optional list of floats (precomputed)

If embeddings are missing, they will be computed on device at startup.
