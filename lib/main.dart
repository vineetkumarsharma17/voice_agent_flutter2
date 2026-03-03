import 'package:flutter/material.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' show initBindings;

import 'home_screen.dart';
import 'voice_agent/controller.dart';
import 'voice_agent/model_registry.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  initBindings();
  runApp(const VoiceAgentApp());
}

class VoiceAgentApp extends StatelessWidget {
  const VoiceAgentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Offline Voice Agent',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class VoiceAgentHome extends StatefulWidget {
  const VoiceAgentHome({super.key});

  @override
  State<VoiceAgentHome> createState() => _VoiceAgentHomeState();
}

class _VoiceAgentHomeState extends State<VoiceAgentHome> {
  late final VoiceAgentController _controller;

  @override
  void initState() {
    super.initState();
    _controller = VoiceAgentController();
    _controller.addListener(_onUpdate);
  }

  void _onUpdate() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onUpdate);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final profile = ModelRegistry.languages[_controller.language]!;
    final lastIntent = _controller.lastIntent;

    // Build status text
    String statusText = 'Status: ${_controller.state.name}';
    if (_controller.state == AgentState.interrupted &&
        _controller.interruptedByKeyword != null) {
      statusText =
          'Status: interrupted by "${_controller.interruptedByKeyword}"';
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Offline Voice Agent'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              statusText,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            DropdownButton<SupportedLanguage>(
              value: _controller.language,
              onChanged: (value) {
                if (value != null) {
                  _controller.setLanguage(value);
                }
              },
              items: ModelRegistry.languages.values
                  .map(
                    (lang) => DropdownMenuItem(
                      value: lang.language,
                      child: Text(lang.displayName),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 8),
            Text(
              'TTS voice: ${profile.ttsSpeakerName}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (lastIntent != null) ...[
              const SizedBox(height: 4),
              Text(
                'Intent: ${lastIntent.intent} (${(lastIntent.confidence * 100).toStringAsFixed(1)}%)',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 16),
            CheckboxListTile(
              title: const Text('Voice Interruption'),
              value: _controller.voiceInterruptionEnabled,
              onChanged: (value) {
                _controller.setVoiceInterruptionEnabled(value ?? false);
              },
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                ElevatedButton(
                  onPressed: (_controller.state == AgentState.idle ||
                          _controller.state == AgentState.interrupted)
                      ? _controller.start
                      : null,
                  child: const Text('Start'),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: (_controller.state != AgentState.idle &&
                          _controller.state != AgentState.interrupted)
                      ? _controller.stop
                      : null,
                  child: const Text('Stop'),
                ),
              ],
            ),
            if (_controller.lastError != null) ...[
              const SizedBox(height: 12),
              Text(
                _controller.lastError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 20),
            Text(
              'Partial',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 6),
            Expanded(
              child: SingleChildScrollView(
                child: Text(
                  _controller.partial,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Final',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 6),
            Expanded(
              child: SingleChildScrollView(
                child: Text(
                  _controller.finalText,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
