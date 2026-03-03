import 'package:flutter/material.dart';
import 'main.dart';
import 'tts_test_screen.dart';
import 'vad_kws_tts_screen.dart';
import 'word_detection_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Offline Voice Agent'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const SizedBox(height: 40),
            // App Icon or Logo
            Icon(
              Icons.mic,
              size: 80,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 40),

            // Title
            Text(
              'Choose Mode',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 60),

            // Button 1: Full Voice Agent (STT)
            SizedBox(
              width: double.infinity,
              height: 70,
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const VoiceAgentHome(),
                    ),
                  );
                },
                icon: const Icon(Icons.record_voice_over, size: 32),
                label: const Text(
                  'Voice Agent (STT)',
                  style: TextStyle(fontSize: 18),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Button 2: Word Detection (KWS)
            SizedBox(
              width: double.infinity,
              height: 70,
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const WordDetectionScreen(),
                    ),
                  );
                },
                icon: const Icon(Icons.hearing, size: 32),
                label: const Text(
                  'Word Detection (KWS)',
                  style: TextStyle(fontSize: 18),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.secondary,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Button 3: TTS Test
            SizedBox(
              width: double.infinity,
              height: 70,
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const TtsTestScreen(),
                    ),
                  );
                },
                icon: const Icon(Icons.volume_up, size: 32),
                label: const Text(
                  'Test TTS (Text-to-Speech)',
                  style: TextStyle(fontSize: 18),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.teal,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Button 4: KWS + TTS Overlap Test
            SizedBox(
              width: double.infinity,
              height: 70,
              child: ElevatedButton.icon(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const VadKwsTtsScreen(),
                    ),
                  );
                },
                icon: const Icon(Icons.sensors, size: 32),
                label: const Text(
                  'KWS + TTS Overlap Test',
                  style: TextStyle(fontSize: 18),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.deepPurple,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 40),

            // Description
            Text(
              'STT: Full speech-to-text with voice agent\nKWS: Fast keyword spotting\nTTS: Text-to-speech synthesis test\nOverlap: Test KWS while TTS plays',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
