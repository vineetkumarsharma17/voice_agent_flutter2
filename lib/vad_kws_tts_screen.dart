import 'package:flutter/material.dart';

import 'vad_kws_tts_controller.dart';

// ─────────────────────────────────────────────────────────────────────────────
//  ~1-minute long test text (≈ 800 words, ~60 s at natural speaking pace)
// ─────────────────────────────────────────────────────────────────────────────

const String _longTestText = '''
Artificial intelligence has transformed the way we interact with computers and devices in our daily lives. 
From voice assistants that answer our questions to recommendation systems that suggest movies and music, 
AI is everywhere. One of the most exciting areas of AI research is natural language processing, 
which enables machines to understand and generate human language.

Speech recognition systems have improved dramatically in recent years. 
On-device models can now transcribe spoken words with high accuracy even without an internet connection. 
This is important for privacy, latency, and reliability in real-world applications. 
Keyword spotting is a lightweight form of speech recognition that listens continuously for specific trigger words. 
Systems like Amazon Alexa and Google Assistant use keyword spotting to detect their wake words before activating full speech recognition.

Text-to-speech synthesis has also advanced significantly. 
Neural vocoders and end-to-end TTS systems produce natural-sounding speech that is difficult to distinguish from a real human voice. 
The Piper TTS system, which powers this application, uses VITS — a variational inference model with adversarial learning. 
It runs entirely on device, producing high-quality audio at real-time speed even on mobile hardware.

Combining keyword detection with simultaneous audio playback is a challenging engineering problem. 
The microphone must remain active while audio plays through the speaker. 
Echo cancellation algorithms attempt to subtract the speaker output from the microphone input, 
but they are not perfect. Background noise, room acoustics, and hardware quality all affect performance.

This test screen lets you evaluate how well keyword spotting works while the device is speaking. 
Try saying the words stop, hello, or hold on while the audio is playing. 
The system should detect your voice even through the playback audio. 
Watch the detection history panel below to see which keywords were detected and whether TTS was active at that moment.

Real-world voice agent systems must handle these situations gracefully. 
A user might interrupt the agent mid-sentence, ask a follow-up question, or say a wake word to restart the conversation. 
Robust barge-in detection is essential for a natural conversational experience. 
By running this test, you can measure the false positive rate, the false negative rate, 
and the overall reliability of the keyword detection system under realistic conditions.

Thank you for testing this application. The results you observe here will help improve the voice agent pipeline.
''';

// ─────────────────────────────────────────────────────────────────────────────
//  Screen
// ─────────────────────────────────────────────────────────────────────────────

class VadKwsTtsScreen extends StatefulWidget {
  const VadKwsTtsScreen({super.key});

  @override
  State<VadKwsTtsScreen> createState() => _VadKwsTtsScreenState();
}

class _VadKwsTtsScreenState extends State<VadKwsTtsScreen> {
  late final VadKwsTtsController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = VadKwsTtsController();
    _ctrl.addListener(_onUpdate);
    // Pre-load both KWS model and TTS engine as soon as the screen opens.
    _ctrl.initEngines();
  }

  void _onUpdate() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onUpdate);
    _ctrl.dispose();
    super.dispose();
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  Color _kwsStateColor(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return switch (_ctrl.kwsState) {
      KwsState.idle => cs.surfaceVariant,
      KwsState.loading => cs.tertiaryContainer,
      KwsState.listening => cs.primaryContainer,
    };
  }

  Color _ttsStateColor(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return switch (_ctrl.ttsState) {
      TtsState.idle => cs.surfaceVariant,
      TtsState.loading => cs.tertiaryContainer,
      TtsState.synthesising => cs.secondaryContainer,
      TtsState.playing => cs.primaryContainer,
      TtsState.stopped => cs.surfaceVariant,
    };
  }

  String _kwsStateLabel() => switch (_ctrl.kwsState) {
    KwsState.idle => 'Idle',
    KwsState.loading => 'Loading model…',
    KwsState.listening => 'Listening…',
  };

  String _ttsStateLabel() => _ctrl.ttsStatusDetail.isNotEmpty
      ? _ctrl.ttsStatusDetail
      : switch (_ctrl.ttsState) {
          TtsState.idle => 'Idle',
          TtsState.loading => 'Loading engine…',
          TtsState.synthesising => 'Synthesising…',
          TtsState.playing => 'Playing…',
          TtsState.stopped => 'Stopped',
        };

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('KWS + TTS Overlap Test'),
        backgroundColor: cs.primaryContainer,
        foregroundColor: cs.onPrimaryContainer,
        actions: [
          if (_ctrl.detectionHistory.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Clear history',
              onPressed: _ctrl.clearHistory,
            ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // ── Info banner ─────────────────────────────────────────────
            _InfoBanner(keywords: _ctrl.keywords),
            const SizedBox(height: 16),

            // ── KWS panel ───────────────────────────────────────────────
            _SectionCard(
              title: 'Keyword Spotting (Mic)',
              icon: Icons.hearing,
              statusColor: _kwsStateColor(context),
              statusLabel: _kwsStateLabel(),
              errorText: _ctrl.kwsError,
              child: Column(
                children: [
                  // Active keyword flash
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 18,
                    ),
                    decoration: BoxDecoration(
                      color: _ctrl.lastDetectedWord.isNotEmpty
                          ? cs.primary
                          : cs.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: _ctrl.lastDetectedWord.isNotEmpty
                            ? cs.primary
                            : cs.outline.withOpacity(0.3),
                      ),
                      boxShadow: _ctrl.lastDetectedWord.isNotEmpty
                          ? [
                              BoxShadow(
                                color: cs.primary.withOpacity(0.35),
                                blurRadius: 18,
                                spreadRadius: 2,
                              ),
                            ]
                          : null,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _ctrl.lastDetectedWord.isNotEmpty
                              ? Icons.record_voice_over
                              : Icons.mic_none,
                          color: _ctrl.lastDetectedWord.isNotEmpty
                              ? cs.onPrimary
                              : cs.onSurfaceVariant,
                          size: 28,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          _ctrl.lastDetectedWord.isNotEmpty
                              ? _ctrl.lastDetectedWord.toUpperCase()
                              : (_ctrl.kwsRunning
                                    ? 'Waiting for keyword…'
                                    : 'Not listening'),
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                            color: _ctrl.lastDetectedWord.isNotEmpty
                                ? cs.onPrimary
                                : cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  // KWS buttons
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _ctrl.kwsState == KwsState.idle
                              ? _ctrl.startKws
                              : null,
                          icon: _ctrl.kwsState == KwsState.loading
                              ? const _SmallSpinner()
                              : const Icon(Icons.mic),
                          label: const Text('Start KWS'),
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _ctrl.kwsRunning ? _ctrl.stopKws : null,
                          icon: const Icon(Icons.mic_off),
                          label: const Text('Stop KWS'),
                          style: FilledButton.styleFrom(
                            backgroundColor: cs.error,
                            foregroundColor: cs.onError,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // ── TTS panel ────────────────────────────────────────────────
            _SectionCard(
              title: 'Text-to-Speech Playback',
              icon: Icons.volume_up,
              statusColor: _ttsStateColor(context),
              statusLabel: _ttsStateLabel(),
              errorText: _ctrl.ttsError,
              child: Column(
                children: [
                  // Waveform / playing indicator
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 18,
                    ),
                    decoration: BoxDecoration(
                      color: _ctrl.ttsRunning
                          ? cs.secondary.withOpacity(0.15)
                          : cs.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: _ctrl.ttsRunning
                            ? cs.secondary
                            : cs.outline.withOpacity(0.3),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          _ctrl.ttsRunning
                              ? Icons.graphic_eq
                              : Icons.volume_off,
                          color: _ctrl.ttsRunning
                              ? cs.secondary
                              : cs.onSurfaceVariant,
                          size: 28,
                        ),
                        const SizedBox(width: 12),
                        Flexible(
                          child: Text(
                            _ttsStateLabel(),
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: _ctrl.ttsRunning
                                  ? cs.secondary
                                  : cs.onSurfaceVariant,
                              fontWeight: _ctrl.ttsRunning
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                        ),
                        if (_ctrl.ttsRunning) ...[
                          const SizedBox(width: 8),
                          const _SmallSpinner(),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  // TTS buttons
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _ctrl.ttsRunning
                              ? null
                              : () => _ctrl.startTts(_longTestText),
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Play ~1 min'),
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.teal,
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _ctrl.ttsRunning ? _ctrl.stopTts : null,
                          icon: const Icon(Icons.stop),
                          label: const Text('Stop TTS'),
                          style: FilledButton.styleFrom(
                            backgroundColor: cs.error,
                            foregroundColor: cs.onError,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // ── Detection history ────────────────────────────────────────
            Card(
              elevation: 1,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.history, color: cs.primary, size: 20),
                        const SizedBox(width: 8),
                        Text(
                          'Detection History',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '${_ctrl.detectionHistory.length} events',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: cs.outline,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (_ctrl.detectionHistory.isEmpty)
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 20),
                          child: Text(
                            'No detections yet.\nStart KWS and say a keyword.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: cs.outline,
                            ),
                          ),
                        ),
                      )
                    else
                      ListView.separated(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: _ctrl.detectionHistory.length,
                        separatorBuilder: (_, __) =>
                            const Divider(height: 1, indent: 40),
                        itemBuilder: (context, i) {
                          final event = _ctrl.detectionHistory[i];
                          return ListTile(
                            dense: true,
                            leading: CircleAvatar(
                              radius: 14,
                              backgroundColor: event.duringTts
                                  ? cs.tertiaryContainer
                                  : cs.primaryContainer,
                              child: Icon(
                                event.duringTts
                                    ? Icons.surround_sound
                                    : Icons.record_voice_over,
                                size: 14,
                                color: event.duringTts
                                    ? cs.onTertiaryContainer
                                    : cs.onPrimaryContainer,
                              ),
                            ),
                            title: Text(
                              event.keyword,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                            subtitle: Text(
                              event.duringTts
                                  ? '${event.timeLabel}  •  🔊 detected during TTS playback'
                                  : '${event.timeLabel}  •  🔇 detected without TTS',
                              style: TextStyle(
                                fontSize: 11,
                                color: event.duringTts
                                    ? cs.tertiary
                                    : cs.outline,
                              ),
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ),
            ),

            // ── Active keywords chip list ──────────────────────────────
            const SizedBox(height: 14),
            Card(
              elevation: 1,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.label_outline,
                          color: cs.secondary,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Active Keywords',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: _ctrl.keywords
                          .map(
                            (k) => Chip(
                              label: Text(
                                k,
                                style: const TextStyle(fontSize: 12),
                              ),
                              backgroundColor: cs.primaryContainer,
                              side: BorderSide.none,
                            ),
                          )
                          .toList(),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Say these words while TTS is playing to test overlap detection.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.outline,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
//  Helper widgets
// ─────────────────────────────────────────────────────────────────────────────

class _InfoBanner extends StatelessWidget {
  const _InfoBanner({required this.keywords});
  final List<String> keywords;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.tertiaryContainer.withOpacity(0.6),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, color: cs.tertiary, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Start KWS (mic) and TTS (speaker) simultaneously.\n'
              'Say a keyword while the audio plays to test overlap detection.\n'
              'History shows whether each detection happened during TTS playback.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onTertiaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.icon,
    required this.statusColor,
    required this.statusLabel,
    required this.child,
    this.errorText,
  });

  final String title;
  final IconData icon;
  final Color statusColor;
  final String statusLabel;
  final Widget child;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Icon(icon, color: cs.primary, size: 20),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                // Status pill
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    statusLabel,
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            // Error
            if (errorText != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: cs.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.error_outline,
                      color: cs.onErrorContainer,
                      size: 16,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        errorText!,
                        style: TextStyle(
                          color: cs.onErrorContainer,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}

class _SmallSpinner extends StatelessWidget {
  const _SmallSpinner();

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 16,
    height: 16,
    child: CircularProgressIndicator(
      strokeWidth: 2,
      color: Theme.of(context).colorScheme.onPrimary,
    ),
  );
}
