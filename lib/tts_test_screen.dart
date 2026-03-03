import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import 'voice_agent/audio_utils.dart';
import 'voice_agent/model_registry.dart';
import 'voice_agent/tts_engine.dart';
import 'voice_agent/wav_utils.dart';

// ── Screen ─────────────────────────────────────────────────────────────────────
class TtsTestScreen extends StatefulWidget {
  const TtsTestScreen({super.key});

  @override
  State<TtsTestScreen> createState() => _TtsTestScreenState();
}

class _TtsTestScreenState extends State<TtsTestScreen> {
  static const String _defaultSentence =
      'Hello! This is a text-to-speech test. I need to test on-device TTS performance and audio playback in my Flutter app.';

  final TextEditingController _textController =
      TextEditingController(text: _defaultSentence);
  final AudioPlayer _player = AudioPlayer();

  TtsEngine? _ttsEngine;
  SupportedLanguage _selectedLanguage = SupportedLanguage.enUS;

  bool _isInitializing = false;
  bool _isSpeaking = false;
  int _speakToken = 0; // Incremented each time _speak() is called
  String? _errorMessage;
  String? _statusMessage;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _loadEngine();

    _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        if (mounted && _isSpeaking) {
          setState(() {
            _isSpeaking = false;
            _statusMessage = 'Playback completed.';
          });
        }
      }
    });
  }

  @override
  void dispose() {
    _textController.dispose();
    _player.dispose();
    _ttsEngine?.dispose();
    super.dispose();
  }

  // ── Engine loading ────────────────────────────────────────────────────────

  Future<void> _loadEngine() async {
    if (_ttsEngine != null) return;
    if (!mounted) return;
    setState(() {
      _isInitializing = true;
      _statusMessage = 'Loading TTS model…';
      _errorMessage = null;
    });

    final watch = Stopwatch()..start();
    try {
      _ttsEngine = await TtsEngine.init();
      watch.stop();
      debugPrint(
          '[TTS] ✅ Engine initialised in ${watch.elapsedMilliseconds} ms');
      if (mounted) {
        setState(() {
          _isInitializing = false;
          _statusMessage =
              'Ready ✓  (loaded in ${watch.elapsedMilliseconds} ms)';
        });
      }
    } catch (e) {
      watch.stop();
      debugPrint(
          '[TTS] ❌ Engine init failed after ${watch.elapsedMilliseconds} ms: $e');
      if (mounted) {
        setState(() {
          _isInitializing = false;
          _errorMessage = 'Failed to load TTS model: $e';
          _statusMessage = null;
        });
      }
    }
  }

  // ── Speak ─────────────────────────────────────────────────────────────────

  Future<void> _speak() async {
    final text = _textController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter some text first.')),
      );
      return;
    }

    if (_ttsEngine == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('TTS engine still loading…')),
      );
      return;
    }

    // Bump session token so stale completion events are ignored.
    final thisSession = ++_speakToken;

    setState(() {
      _isSpeaking = true;
      _statusMessage = 'Synthesising…';
      _errorMessage = null;
    });

    final profile = ModelRegistry.languages[_selectedLanguage]!;
    debugPrint(
        '[TTS] 🔊 synthesizeStream (realtime PCM) — ${text.length} chars,'
        ' speaker: ${profile.ttsSpeakerName}');

    final totalWatch = Stopwatch()..start();
    try {
      // synthesizeStream() emits raw Float32 PCM chunks from the isolate.
      // We convert each chunk to WAV bytes here on the main isolate (cheap —
      // just a header prepend) and append to the playlist so playback starts
      // as soon as the very first sentence is ready.
      final stream = _ttsEngine!.synthesizeStream(
        text: text,
        language: profile,
      );

      bool isFirstChunk = true;
      final playlist = ConcatenatingAudioSource(children: []);

      await _player.stop();

      // If another _speak() was triggered while we awaited, bail out.
      if (_speakToken != thisSession) return;

      await for (final chunk in stream) {
        if (!mounted || _speakToken != thisSession) {
          _ttsEngine!.stopStream();
          break;
        }

        // Convert raw PCM → WAV bytes (no disk I/O, runs on main isolate).
        final wavBytes = wavBytesFromSamples(chunk.samples, chunk.sampleRate);
        await playlist.add(BytesAudioSource(wavBytes));

        if (isFirstChunk) {
          isFirstChunk = false;
          // Start playback immediately on the first chunk; subsequent chunks
          // are appended while the player is already running.
          await _player.setAudioSource(playlist,
              initialIndex: 0, initialPosition: Duration.zero);
          unawaited(_player.play());

          if (mounted) {
            setState(() => _statusMessage =
                'Playing chunk 1… (synthesising rest in background)');
          }
        } else if (mounted && _speakToken == thisSession) {
          setState(
              () => _statusMessage = 'Playing… chunk ${chunk.chunkIndex + 1}');
        }
      }

      totalWatch.stop();
      debugPrint(
          '[TTS] ⏱ Stream complete in ${totalWatch.elapsedMilliseconds} ms');
    } catch (e) {
      debugPrint('[TTS] ❌ Error: $e');
      if (mounted) {
        setState(() {
          _isSpeaking = false;
          _errorMessage = 'TTS error: $e';
          _statusMessage = null;
        });
      }
    }
  }

  Future<void> _stop() async {
    _speakToken++; // Cancel any in-flight _speak() session
    await _player.stop();
    setState(() {
      _isSpeaking = false;
      _statusMessage = 'Stopped.';
    });
  }

  void _clearText() {
    _textController.clear();
    setState(() {
      _statusMessage = null;
      _errorMessage = null;
    });
  }

  void _resetDefault() {
    _textController.text = _defaultSentence;
    setState(() {
      _statusMessage = null;
      _errorMessage = null;
    });
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('TTS Test'),
        backgroundColor: cs.primaryContainer,
        foregroundColor: cs.onPrimaryContainer,
        actions: [
          IconButton(
            onPressed: _resetDefault,
            icon: const Icon(Icons.refresh),
            tooltip: 'Reset default sentence',
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Language Selector ──────────────────────────────────────
              Card(
                elevation: 2,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      Icon(Icons.language, color: cs.primary, size: 22),
                      const SizedBox(width: 12),
                      const Text('Language:',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButton<SupportedLanguage>(
                          value: _selectedLanguage,
                          isExpanded: true,
                          underline: const SizedBox.shrink(),
                          items: ModelRegistry.languages.entries
                              .map((e) => DropdownMenuItem(
                                    value: e.key,
                                    child: Text(
                                      '${e.value.displayName} (${e.value.ttsSpeakerName})',
                                      style: const TextStyle(fontSize: 13),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ))
                              .toList(),
                          onChanged: _isSpeaking
                              ? null
                              : (value) {
                                  if (value != null &&
                                      value != _selectedLanguage) {
                                    setState(() {
                                      _selectedLanguage = value;
                                      _ttsEngine?.dispose();
                                      _ttsEngine = null;
                                      _statusMessage =
                                          'Language changed — reloading engine…';
                                    });
                                    _loadEngine();
                                  }
                                },
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // ── Text Input ─────────────────────────────────────────────
              Text('Text to Synthesise',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              TextField(
                controller: _textController,
                maxLines: 6,
                minLines: 4,
                enabled: !_isSpeaking,
                decoration: InputDecoration(
                  hintText: 'Enter text here…',
                  filled: true,
                  fillColor: cs.surfaceVariant.withOpacity(0.4),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12)),
                  contentPadding: const EdgeInsets.all(14),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.clear),
                    tooltip: 'Clear text',
                    onPressed: _isSpeaking ? null : _clearText,
                  ),
                ),
                style: const TextStyle(fontSize: 15, height: 1.5),
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: ValueListenableBuilder(
                  valueListenable: _textController,
                  builder: (_, __, ___) => Text(
                    '${_textController.text.length} chars',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ),

              const SizedBox(height: 20),

              // ── Quick presets ──────────────────────────────────────────
              Text('Quick Presets',
                  style: theme.textTheme.titleSmall?.copyWith(
                      color: cs.secondary, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: _presets
                    .map((p) => ActionChip(
                          label: Text(p['label']!,
                              style: const TextStyle(fontSize: 12)),
                          onPressed: _isSpeaking
                              ? null
                              : () {
                                  _textController.text = p['text']!;
                                  setState(() {});
                                },
                        ))
                    .toList(),
              ),

              const SizedBox(height: 24),

              // ── Loading bar ────────────────────────────────────────────
              if (_isInitializing)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: LinearProgressIndicator(
                    minHeight: 6,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),

              // ── Status / Error ─────────────────────────────────────────
              if (_errorMessage != null)
                Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                      color: cs.errorContainer,
                      borderRadius: BorderRadius.circular(10)),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline,
                          color: cs.onErrorContainer, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(_errorMessage!,
                            style: TextStyle(
                                color: cs.onErrorContainer, fontSize: 13)),
                      ),
                    ],
                  ),
                ),
              if (_statusMessage != null && _errorMessage == null)
                Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                      color: cs.secondaryContainer,
                      borderRadius: BorderRadius.circular(10)),
                  child: Row(
                    children: [
                      if (_isInitializing || _isSpeaking)
                        Padding(
                          padding: const EdgeInsets.only(right: 10),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: cs.onSecondaryContainer),
                          ),
                        ),
                      Expanded(
                        child: Text(_statusMessage!,
                            style: TextStyle(
                                color: cs.onSecondaryContainer, fontSize: 13)),
                      ),
                    ],
                  ),
                ),

              // ── Speak / Stop ───────────────────────────────────────────
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed:
                          (_isInitializing || _isSpeaking) ? null : _speak,
                      icon: _isInitializing
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.volume_up),
                      label: Text(_isInitializing ? 'Loading model…' : 'Speak'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        textStyle: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                  if (_isSpeaking) ...[
                    const SizedBox(width: 12),
                    IconButton.filled(
                      onPressed: _stop,
                      icon: const Icon(Icons.stop),
                      tooltip: 'Stop',
                      style: IconButton.styleFrom(
                        backgroundColor: cs.error,
                        foregroundColor: cs.onError,
                        padding: const EdgeInsets.all(14),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _isSpeaking ? null : _clearText,
                icon: const Icon(Icons.clear_all),
                label: const Text('Clear Text'),
                style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

const List<Map<String, String>> _presets = [
  {
    'label': 'Greeting',
    'text': 'Hello! How are you doing today?',
  },
  {
    'label': 'Numbers',
    'text': 'One, two, three. The price is twelve dollars and fifty cents.',
  },
  {
    'label': 'Pangram',
    'text': 'The quick brown fox jumps over the lazy dog.',
  },
  {
    'label': 'Question',
    'text': 'What time is it? Can you set an alarm for seven thirty?',
  },
  {
    'label': 'Long',
    'text':
        'Artificial intelligence is transforming the way we interact with technology. Voice assistants powered by neural networks can now understand and generate natural speech with remarkable accuracy.',
  },
];
