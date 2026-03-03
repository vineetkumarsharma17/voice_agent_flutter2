import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:record/record.dart';

import 'audio_session_manager.dart';
import 'audio_utils.dart';
import 'asr_engine.dart';
import 'intent/intent_engine.dart';
import 'intent/response_generator.dart';
import 'intent/dialog_state.dart';
import 'intent/response_selector.dart';
import 'intent/slot_engine.dart';
import 'model_registry.dart';
import 'tts_engine.dart';
import 'vad_engine.dart';

enum AgentState {
  idle,
  listening,
  thinking,
  speaking,
  interrupted,
}

// Voice interruption keywords
const List<String> interruptionKeywords = [
  'stop',
  'hold on',
  'pause',
  'wait',
  'cancel',
];

class AgentConfig {
  const AgentConfig({
    this.sampleRate = 16000,
    this.endpointSilenceMs = 250,
    this.bargeInEnabled = true,
    this.bargeInDelayMs = 200,
    this.bargeInRmsThreshold = 0.02,
    this.noiseCalibrationMs = 1500,
    this.noiseFloorMultiplier = 2.5,
    this.noiseFloorAdaptation = 0.02,
    this.speechConfirmFrames = 3,
    this.bargeInConfirmFrames = 3,
    this.uiUpdateIntervalMs = 80,
    this.vadSettings = const VadSettings(),
    this.enableNoiseSuppress = true,
    this.enableEchoCancel = true,
    this.enableAutoGain = true,
    this.useVoiceCommunicationSource = true,
    this.androidSpeakerphone = false,
  });

  final int sampleRate;
  final int endpointSilenceMs;
  final bool bargeInEnabled;
  final int bargeInDelayMs;
  final double bargeInRmsThreshold;
  final int noiseCalibrationMs;
  final double noiseFloorMultiplier;
  final double noiseFloorAdaptation;
  final int speechConfirmFrames;
  final int bargeInConfirmFrames;
  final int uiUpdateIntervalMs;
  final VadSettings vadSettings;
  final bool enableNoiseSuppress;
  final bool enableEchoCancel;
  final bool enableAutoGain;
  final bool useVoiceCommunicationSource;
  final bool androidSpeakerphone;
}

class VoiceAgentController extends ChangeNotifier {
  VoiceAgentController({AgentConfig config = const AgentConfig()})
      : _config = config {
    _player.playerStateStream.listen((state) {
      if (_state == AgentState.speaking &&
          state.processingState == ProcessingState.completed) {
        _state = AgentState.listening;
        _ttsStartMs = null;
        notifyListeners();
      }
    });
  }

  final AgentConfig _config;
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();

  StreamSubscription<Uint8List>? _audioSub;
  AsrEngine? _asr;
  TtsEngine? _tts;
  VadEngine? _vad;
  IntentEngine? _intent;
  SlotEngine? _slotEngine;
  ResponseSelector? _responseSelector;
  ResponseGenerator? _responseGenerator;
  final DialogState _dialogState = DialogState();

  AgentState _state = AgentState.idle;
  SupportedLanguage _language = SupportedLanguage.enUS;

  String _partial = '';
  String _finalText = '';
  String? _lastError;
  IntentResult? _lastIntent;
  bool _voiceInterruptionEnabled = false;
  String? _interruptedByKeyword;
  Timer? _interruptionResetTimer;

  bool _starting = false;
  int _turnToken = 0;
  int _speechToken = 0;
  int? _lastSpeechMs;
  int? _ttsStartMs;
  int _lastUiUpdateMs = 0;
  int _speechFrameCount = 0;
  bool _speechConfirmed = false;
  bool _speechConfirmedEver = false;
  int? _noiseStartMs;
  double _noiseRmsSum = 0.0;
  int _noiseRmsCount = 0;
  double? _noiseFloorRms;

  AgentState get state => _state;
  SupportedLanguage get language => _language;
  String get partial => _partial;
  String get finalText => _finalText;
  String? get lastError => _lastError;
  IntentResult? get lastIntent => _lastIntent;
  bool get voiceInterruptionEnabled => _voiceInterruptionEnabled;
  String? get interruptedByKeyword => _interruptedByKeyword;

  void setVoiceInterruptionEnabled(bool enabled) {
    _voiceInterruptionEnabled = enabled;
    notifyListeners();
  }

  Future<void> setLanguage(SupportedLanguage language) async {
    if (_language == language) return;
    _language = language;
    await _rebuildAsr();
    if (_state != AgentState.idle) {
      _asr?.reset();
    }
    notifyListeners();
  }

  Future<void> start() async {
    if ((_state != AgentState.idle && _state != AgentState.interrupted) ||
        _starting) return;
    _starting = true;
    _lastError = null;
    _interruptedByKeyword = null;
    _interruptionResetTimer?.cancel();
    try {
      await AudioSessionManager.configure();
      await _ensureEngines();
      final hasPermission = await _recorder.hasPermission();
      if (!hasPermission) {
        _lastError = 'Microphone permission denied.';
        notifyListeners();
        return;
      }

      _lastSpeechMs = null;
      _resetSpeechConfirmation();
      _resetNoiseCalibration();
      _vad?.reset();
      _asr?.reset();

      final stream = await _recorder.startStream(
        RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          numChannels: 1,
          sampleRate: _config.sampleRate,
          autoGain: _config.enableAutoGain,
          echoCancel: _config.enableEchoCancel,
          noiseSuppress: _config.enableNoiseSuppress,
          androidConfig: AndroidRecordConfig(
            audioSource: _config.useVoiceCommunicationSource
                ? AndroidAudioSource.voiceCommunication
                : AndroidAudioSource.mic,
            audioManagerMode: _config.useVoiceCommunicationSource
                ? AudioManagerMode.modeInCommunication
                : AudioManagerMode.modeNormal,
            speakerphone: _config.androidSpeakerphone,
          ),
        ),
      );

      _audioSub = stream.listen(
        _onAudioData,
        onError: (Object error) {
          _lastError = error.toString();
          notifyListeners();
        },
      );

      _state = AgentState.listening;
      notifyListeners();
    } catch (e) {
      _lastError = e.toString();
      notifyListeners();
    } finally {
      _starting = false;
    }
  }

  Future<void> stop() async {
    _turnToken++;
    _speechToken++;
    _interruptionResetTimer?.cancel();
    await _audioSub?.cancel();
    _audioSub = null;
    await _recorder.stop();
    await _player.stop();
    await AudioSessionManager.deactivate();
    _state = AgentState.idle;
    _partial = '';
    _finalText = '';
    _lastIntent = null;
    _interruptedByKeyword = null;
    _dialogState.slots.clear();
    _dialogState.userHistory.clear();
    _dialogState.agentHistory.clear();
    _dialogState.turn = 0;
    _resetSpeechConfirmation();
    _resetNoiseCalibration();
    _ttsStartMs = null;
    notifyListeners();
  }

  Future<void> _ensureEngines() async {
    _tts ??= await TtsEngine.init();
    _vad ??= await VadEngine.create(settings: _config.vadSettings);
    // TFLite-based engines are optional — fall back to hardcoded responses if missing
    if (_intent == null) {
      try {
        _intent = await IntentEngine.create(numThreads: 2);
      } catch (_) {
        debugPrint('Intent model not available; using fallback intent.');
      }
    }
    if (_slotEngine == null) {
      try {
        _slotEngine = await SlotEngine.create(numThreads: 2);
      } catch (_) {
        debugPrint('Slot model not available; using regex extraction only.');
      }
    }
    if (_responseSelector == null) {
      try {
        _responseSelector =
            await ResponseSelector.create(ModelRegistry.responseModel);
      } catch (_) {
        debugPrint(
            'Response selector not available; using template responses.');
      }
    }
    _responseGenerator ??= ResponseGenerator(
      selector: _responseSelector,
      slotEngine: _slotEngine,
    );
    await _rebuildAsr();
  }

  Future<void> _rebuildAsr() async {
    _asr?.dispose();
    final profile = ModelRegistry.languages[_language]!;
    _asr = await AsrEngine.create(profile.asr);
  }

  void _onAudioData(Uint8List data) {
    if (_asr == null || _vad == null) return;
    if (data.isEmpty) return;

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final prevPartial = _partial;
    final prevFinal = _finalText;

    final samples = pcm16BytesToFloat32(data);
    final frameRms = rms(samples);
    final vadEvent =
        _vad!.update(samples: samples, sampleRate: _config.sampleRate);

    final energyThreshold = _energyThreshold();
    final energyOk = frameRms >= energyThreshold;
    final vadSpeech =
        vadEvent == VadEvent.speechStart || vadEvent == VadEvent.speech;

    _updateNoiseFloor(nowMs, frameRms, vadSpeech && energyOk);

    if (vadSpeech && energyOk) {
      _speechFrameCount += 1;
      if (_speechFrameCount >= _config.speechConfirmFrames) {
        _speechConfirmed = true;
        _speechConfirmedEver = true;
        _lastSpeechMs = nowMs;
      }
    } else {
      _speechFrameCount = 0;
      _speechConfirmed = false;
    }

    if (_state == AgentState.speaking && _config.bargeInEnabled) {
      final ttsStart = _ttsStartMs ?? nowMs;
      final delayOk = nowMs - ttsStart >= _config.bargeInDelayMs;
      final confirmOk = _speechFrameCount >= _config.bargeInConfirmFrames;
      if (delayOk && energyOk && confirmOk) {
        unawaited(_bargeIn());
        return;
      }
    }

    if (_state == AgentState.thinking && _speechConfirmed) {
      _turnToken++;
      _state = AgentState.listening;
      _asr?.reset();
      _resetSpeechConfirmation();
    }

    if (_state != AgentState.listening) return;

    _asr!.acceptSamples(samples, _config.sampleRate);
    _partial = _asr!.decodeAndGetPartial();

    // Voice interruption detection
    if (_voiceInterruptionEnabled && _partial.isNotEmpty) {
      final lowerText = _partial.toLowerCase();
      final foundKeyword = interruptionKeywords.firstWhere(
        (keyword) => lowerText.contains(keyword),
        orElse: () => '',
      );
      if (foundKeyword.isNotEmpty) {
        _handleInterruption(foundKeyword);
        return;
      }
    }

    if (_asr!.isEndpoint()) {
      final lastSpeech = _lastSpeechMs ?? nowMs;
      final silenceMs = nowMs - lastSpeech;
      if (silenceMs >= _config.endpointSilenceMs) {
        if (!_speechConfirmedEver) {
          _asr!.reset();
          _partial = '';
          _resetSpeechConfirmation();
          return;
        }
        final text = _asr!.finalResult().trim();
        _asr!.reset();
        _partial = '';
        _resetSpeechConfirmation();
        if (text.isNotEmpty) {
          _finalText = text;
          unawaited(_handleFinal(text));
        }
      }
    }

    if (prevPartial != _partial || prevFinal != _finalText) {
      _notifyUi(nowMs);
    }
  }

  Future<void> _handleFinal(String text) async {
    final turn = ++_turnToken;
    _state = AgentState.thinking;
    notifyListeners();

    try {
      final profile = ModelRegistry.languages[_language]!;
      final intent = _intent == null
          ? IntentResult.fallback
          : await _intent!.classify(text: text, profile: profile);
      _lastIntent = intent;
      final response = await _responseGenerator!.generate(
        userText: text,
        profile: profile,
        intent: intent,
        state: _dialogState,
      );
      if (!_isTurnActive(turn)) return;
      await _speak(response.text, profile, turn);
    } catch (e) {
      _lastError = e.toString();
      _state = AgentState.listening;
      notifyListeners();
    }
  }

  Future<void> _speak(
    String text,
    LanguageProfile profile,
    int turn,
  ) async {
    if (_tts == null) return;
    if (!_isTurnActive(turn)) return;

    final speech = ++_speechToken;
    _state = AgentState.speaking;
    _ttsStartMs = DateTime.now().millisecondsSinceEpoch;
    notifyListeners();

    final stream = _tts!.synthesizeStreaming(
      text: text,
      language: profile,
    );

    bool isFirstChunk = true;
    final playlist = ConcatenatingAudioSource(children: []);

    await _player.stop();

    await for (final wavBytes in stream) {
      if (!_isTurnActive(turn) || !_isSpeechActive(speech)) return;

      await playlist.add(BytesAudioSource(wavBytes));

      if (isFirstChunk) {
        isFirstChunk = false;
        // Set audio source only after the first chunk is available,
        // otherwise an empty playlist triggers immediate completion.
        await _player.setAudioSource(playlist,
            initialIndex: 0, initialPosition: Duration.zero);
        unawaited(_player.play());
      }
    }
  }

  Future<void> _bargeIn() async {
    _turnToken++;
    _speechToken++;
    await _player.stop();
    _vad?.reset();
    _asr?.reset();
    _resetSpeechConfirmation();
    _state = AgentState.listening;
    _ttsStartMs = null;
    notifyListeners();
  }

  void _handleInterruption(String keyword) {
    _interruptedByKeyword = keyword;
    _state = AgentState.interrupted;

    // Stop listening immediately
    _turnToken++;
    _speechToken++;
    _audioSub?.cancel();
    _audioSub = null;
    _recorder.stop();
    _player.stop();

    // Reset state
    _asr?.reset();
    _vad?.reset();
    _resetSpeechConfirmation();
    _partial = '';

    notifyListeners();

    // Reset to idle after 3 seconds
    _interruptionResetTimer?.cancel();
    _interruptionResetTimer = Timer(const Duration(seconds: 3), () {
      if (_state == AgentState.interrupted) {
        _state = AgentState.idle;
        _interruptedByKeyword = null;
        AudioSessionManager.deactivate();
        notifyListeners();
      }
    });
  }

  bool _isTurnActive(int token) =>
      token == _turnToken && _state != AgentState.idle;

  bool _isSpeechActive(int token) =>
      token == _speechToken && _state == AgentState.speaking;

  void _notifyUi(int nowMs) {
    if (nowMs - _lastUiUpdateMs >= _config.uiUpdateIntervalMs) {
      _lastUiUpdateMs = nowMs;
      notifyListeners();
    }
  }

  void _resetSpeechConfirmation() {
    _speechFrameCount = 0;
    _speechConfirmed = false;
    _speechConfirmedEver = false;
    _lastSpeechMs = null;
  }

  void _resetNoiseCalibration() {
    _noiseStartMs = null;
    _noiseRmsSum = 0.0;
    _noiseRmsCount = 0;
    _noiseFloorRms = null;
  }

  void _updateNoiseFloor(int nowMs, double frameRms, bool speechCandidate) {
    _noiseStartMs ??= nowMs;

    if (_noiseFloorRms == null) {
      if (!speechCandidate) {
        _noiseRmsSum += frameRms;
        _noiseRmsCount += 1;
      }
      if (nowMs - _noiseStartMs! >= _config.noiseCalibrationMs) {
        _noiseFloorRms = _noiseRmsCount == 0
            ? _config.bargeInRmsThreshold
            : _noiseRmsSum / _noiseRmsCount;
      }
      return;
    }

    if (!speechCandidate) {
      final adapt = _config.noiseFloorAdaptation;
      _noiseFloorRms = (_noiseFloorRms! * (1.0 - adapt)) + (frameRms * adapt);
    }
  }

  double _energyThreshold() {
    final base = _config.bargeInRmsThreshold;
    final noise = _noiseFloorRms;
    if (noise == null || noise <= 0) return base;
    final dynamicThresh = noise * _config.noiseFloorMultiplier;
    return dynamicThresh > base ? dynamicThresh : base;
  }

  @override
  void dispose() {
    _interruptionResetTimer?.cancel();
    _audioSub?.cancel();
    _recorder.dispose();
    _player.dispose();
    _asr?.dispose();
    _tts?.dispose();
    _vad?.dispose();
    _intent?.dispose();
    _slotEngine?.dispose();
    _responseSelector?.dispose();
    super.dispose();
  }
}
