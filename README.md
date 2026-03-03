# Offline Voice Agent (Flutter)

This Flutter app implements an interruption-safe, offline voice agent using open-source models:
- Streaming ASR for low latency (sherpa-onnx)
- Kokoro TTS for high-quality North American voices
- Silero VAD for barge-in detection
- Local intent classification (TFLite)
- Local response generator with dialog state, entity extraction, and clarifications
- Model-driven response selector (TFLite encoder + response bank)
- Built-in noise suppression / echo cancellation via platform audio effects

## Quick Start
1. Create platform scaffolding (if you don't already have it):
   - `flutter create .`
2. Download model files listed in `docs/MODEL_DOWNLOADS.md`.
3. Run:
   - `flutter pub get`
   - `flutter run`

## Interruption-safe pipeline
- Microphone audio is continuously captured.
- VAD runs on the live audio stream to detect speech while TTS is playing.
- If speech starts during TTS playback, TTS is stopped immediately (barge-in).
- The ASR stream is reset and resumes in `listening` state.

## Production audio configuration
- This app configures a speech-optimized audio session via the `audio_session` package.
- For iOS, ensure `NSMicrophoneUsageDescription` is set in `Info.plist` after running
  `flutter create .`.
- For Android, ensure `RECORD_AUDIO` permission is present (Flutter adds it automatically).

## Notes
- Kokoro multi-lingual voices include Spanish and French speakers, but lexicon support
  is strongest for English out of the box. For best Spanish/French pronunciation, add
  language-specific lexicons or a phonemizer pipeline.
- If you need North American regional accents (es-MX or fr-CA), you will likely need
  custom open-source voice training or a commercial embedded TTS engine.
- Intent classification models are loaded from `assets/models/intent/*` and must include
  `model.tflite`, `vocab.txt`, and `labels.txt` per language.
- Noise suppression and echo cancellation are enabled in `RecordConfig` and are device-dependent.
- This app intentionally keeps all computation on-device (no network calls).
