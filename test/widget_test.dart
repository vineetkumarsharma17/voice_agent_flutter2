import 'package:flutter_test/flutter_test.dart';

import 'package:voice_agent_flutter/main.dart';

void main() {
  testWidgets('App renders title', (WidgetTester tester) async {
    await tester.pumpWidget(const VoiceAgentApp());
    expect(find.text('Offline Voice Agent'), findsOneWidget);
  });
}
