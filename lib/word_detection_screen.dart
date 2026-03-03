import 'package:flutter/material.dart';
import 'word_detection_controller.dart';

class WordDetectionScreen extends StatefulWidget {
  const WordDetectionScreen({super.key});

  @override
  State<WordDetectionScreen> createState() => _WordDetectionScreenState();
}

class _WordDetectionScreenState extends State<WordDetectionScreen> {
  late final WordDetectionController _controller;

  @override
  void initState() {
    super.initState();
    _controller = WordDetectionController();
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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Keyword Spotting'),
        actions: [
          if (_controller.detectionHistory.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () {
                _controller.clearHistory();
              },
              tooltip: 'Clear History',
            ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: ListView(
          // crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status
            Text(
              'Status: ${_controller.state.name}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 20),

            // Active Keywords Section
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Active Keywords',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _controller.keywords
                          .map((keyword) => Chip(
                                label: Text(keyword),
                                backgroundColor: Theme.of(context)
                                    .colorScheme
                                    .primaryContainer,
                              ))
                          .toList(),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            // Start/Stop Buttons
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _controller.state == WordDetectionState.idle
                      ? _controller.start
                      : null,
                  icon: const Icon(Icons.mic),
                  label: const Text('Start Listening'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: _controller.state != WordDetectionState.idle
                      ? _controller.stop
                      : null,
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                  ),
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
            const SizedBox(height: 30),

            // Detected Word Display
            Center(
              child: Container(
                padding: const EdgeInsets.all(30),
                decoration: BoxDecoration(
                  color: _controller.detectedWord.isNotEmpty
                      ? Theme.of(context).colorScheme.primary
                      : Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: _controller.detectedWord.isNotEmpty
                      ? [
                          BoxShadow(
                            color: Theme.of(context)
                                .colorScheme
                                .primary
                                .withOpacity(0.4),
                            blurRadius: 20,
                            spreadRadius: 5,
                          )
                        ]
                      : null,
                ),
                child: Column(
                  children: [
                    Icon(
                      _controller.detectedWord.isNotEmpty
                          ? Icons.hearing
                          : Icons.hearing_disabled,
                      size: 60,
                      color: _controller.detectedWord.isNotEmpty
                          ? Colors.white
                          : Colors.grey,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _controller.detectedWord.isEmpty
                          ? 'Listening...'
                          : _controller.detectedWord.toUpperCase(),
                      style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        color: _controller.detectedWord.isNotEmpty
                            ? Colors.white
                            : Colors.grey,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 30),

            // Detection History
            Text(
              'Detection History',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            _controller.detectionHistory.isEmpty
                ? Center(
                    child: Text(
                      'No detections yet',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  )
                : ListView.builder(
                    itemCount: _controller.detectionHistory.length,
                    shrinkWrap: true,
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemBuilder: (context, index) {
                      return Card(
                        child: ListTile(
                          leading: const Icon(Icons.check_circle,
                              color: Colors.green),
                          title: Text(_controller.detectionHistory[index]),
                          dense: true,
                        ),
                      );
                    },
                  ),
          ],
        ),
      ),
    );
  }
}
