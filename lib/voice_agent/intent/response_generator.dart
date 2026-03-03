import 'dart:math' as math;

import '../model_registry.dart';
import 'dialog_state.dart';
import 'entity_extractor.dart';
import 'intent_engine.dart';
import 'response_selector.dart';
import 'slot_engine.dart';

class ResponseGenerator {
  ResponseGenerator({
    required this.selector,
    required this.slotEngine,
    this.confidenceThreshold = 0.55,
    this.repeatPenalty = 0.2,
    math.Random? random,
  }) : _random = random ?? math.Random();

  final ResponseSelector? selector;
  final SlotEngine? slotEngine;
  final double confidenceThreshold;
  final double repeatPenalty;
  final math.Random _random;
  final EntityExtractor _extractor = EntityExtractor();

  Future<AgentResponse> generate({
    required String userText,
    required LanguageProfile profile,
    required IntentResult intent,
    required DialogState state,
  }) async {
    state.addUser(userText);

    final slotResult = slotEngine == null
        ? const SlotResult(slots: {}, tags: [])
        : await slotEngine!.tag(text: userText, profile: profile);

    if (slotResult.slots.isNotEmpty) {
      state.slots.addAll(slotResult.slots);
    }

    final entities = _extractor.extract(userText, profile.language);
    if (!entities.isEmpty) {
      state.slots.addAll(entities.values);
    }

    final safeIntent = intent.confidence >= confidenceThreshold
        ? intent.intent
        : 'fallback';

    final template = selector == null
        ? null
        : await selector!.select(
            query: _buildQuery(userText, safeIntent, state.slots),
            language: profile.language,
            intent: safeIntent,
            slots: state.slots,
          );

    final response = template == null
        ? _fallbackResponse(profile.language, safeIntent, userText, state)
        : template.render(state.slots);

    state.addAgent(response);

    return AgentResponse(
      text: response,
      intent: safeIntent,
      confidence: intent.confidence,
      slots: Map<String, String>.from(state.slots),
      slotTags: slotResult.tags,
    );
  }

  String _buildQuery(String userText, String intent, Map<String, String> slots) {
    if (slots.isEmpty) return '$userText [intent=$intent]';
    final slotText = slots.entries.map((e) => '${e.key}:${e.value}').join(',');
    return '$userText [intent=$intent] [slots=$slotText]';
  }

  String _fallbackResponse(
    SupportedLanguage language,
    String intent,
    String userText,
    DialogState state,
  ) {
    final name = state.slots['name'];
    final candidates = _baseResponses(language, intent, userText, name);
    if (candidates.isEmpty) {
      return _defaultFallback(language);
    }
    final best = _rank(candidates, state.lastAgent());
    return best.text;
  }

  List<_Candidate> _baseResponses(
    SupportedLanguage language,
    String intent,
    String userText,
    String? name,
  ) {
    switch (language) {
      case SupportedLanguage.esMX:
        return _spanishResponses(intent, userText, name);
      case SupportedLanguage.frCA:
        return _frenchResponses(intent, userText, name);
      case SupportedLanguage.enUS:
        return _englishResponses(intent, userText, name);
    }
  }

  List<_Candidate> _englishResponses(String intent, String userText, String? name) {
    final greeting = name == null ? 'Hi there' : 'Hi $name';
    switch (intent) {
      case 'greeting':
        return [
          _Candidate(text: '$greeting. How can I help you today?', weight: 1.0),
          _Candidate(text: 'Hello. What can I do for you right now?', weight: 0.9),
        ];
      case 'goodbye':
        return [
          _Candidate(text: 'Thanks for stopping by. Goodbye.', weight: 1.0),
          _Candidate(text: 'All set. Talk soon.', weight: 0.9),
        ];
      case 'thanks':
        return [
          _Candidate(text: 'You are welcome. Anything else?', weight: 0.9),
          _Candidate(text: 'Happy to help. Do you need anything else?', weight: 0.9),
        ];
      case 'help':
        return [
          _Candidate(
            text: 'I can help with account info, quick questions, and simple tasks. What do you need?',
            weight: 1.0,
          ),
        ];
      case 'status':
        return [
          _Candidate(text: 'I am online and ready. What would you like to do?', weight: 1.0),
        ];
      case 'repeat':
        return [
          _Candidate(text: _repeat(SupportedLanguage.enUS, userText), weight: 0.9),
        ];
      default:
        return [
          _Candidate(text: 'I did not catch that. Could you rephrase?', weight: 0.8),
          _Candidate(text: 'Sorry, can you say that another way?', weight: 0.8),
        ];
    }
  }

  List<_Candidate> _spanishResponses(String intent, String userText, String? name) {
    final greeting = name == null ? 'Hola' : 'Hola $name';
    switch (intent) {
      case 'greeting':
        return [
          _Candidate(text: '$greeting. En que puedo ayudarte?', weight: 1.0),
          _Candidate(text: 'Hola. Como puedo ayudarte hoy?', weight: 0.9),
        ];
      case 'goodbye':
        return [
          _Candidate(text: 'Gracias. Hasta luego.', weight: 1.0),
          _Candidate(text: 'Listo. Hablamos pronto.', weight: 0.9),
        ];
      case 'thanks':
        return [
          _Candidate(text: 'De nada. Necesitas algo mas?', weight: 0.9),
          _Candidate(text: 'Con gusto. Algo mas?', weight: 0.9),
        ];
      case 'help':
        return [
          _Candidate(
            text: 'Puedo ayudar con informacion basica y tareas rapidas. Que necesitas?',
            weight: 1.0,
          ),
        ];
      case 'status':
        return [
          _Candidate(text: 'Estoy listo para ayudarte. Que deseas hacer?', weight: 1.0),
        ];
      case 'repeat':
        return [
          _Candidate(text: _repeat(SupportedLanguage.esMX, userText), weight: 0.9),
        ];
      default:
        return [
          _Candidate(text: 'No entendi bien. Puedes repetirlo?', weight: 0.8),
          _Candidate(text: 'Lo siento, puedes decirlo de otra manera?', weight: 0.8),
        ];
    }
  }

  List<_Candidate> _frenchResponses(String intent, String userText, String? name) {
    final greeting = name == null ? 'Bonjour' : 'Bonjour $name';
    switch (intent) {
      case 'greeting':
        return [
          _Candidate(text: '$greeting. Comment puis-je vous aider?', weight: 1.0),
          _Candidate(text: 'Bonjour. Que puis-je faire pour vous?', weight: 0.9),
        ];
      case 'goodbye':
        return [
          _Candidate(text: 'Merci et a bientot.', weight: 1.0),
          _Candidate(text: 'Tres bien. A bientot.', weight: 0.9),
        ];
      case 'thanks':
        return [
          _Candidate(text: 'Avec plaisir. Autre chose?', weight: 0.9),
          _Candidate(text: 'Je vous en prie. Besoin d autre chose?', weight: 0.9),
        ];
      case 'help':
        return [
          _Candidate(
            text: 'Je peux aider avec des questions simples et des taches rapides. Que voulez-vous faire?',
            weight: 1.0,
          ),
        ];
      case 'status':
        return [
          _Candidate(text: 'Je suis pret a aider. Que souhaitez-vous faire?', weight: 1.0),
        ];
      case 'repeat':
        return [
          _Candidate(text: _repeat(SupportedLanguage.frCA, userText), weight: 0.9),
        ];
      default:
        return [
          _Candidate(text: 'Je n ai pas bien compris. Pouvez-vous reformuler?', weight: 0.8),
          _Candidate(text: 'Desole, pouvez-vous le dire autrement?', weight: 0.8),
        ];
    }
  }

  String _repeat(SupportedLanguage language, String userText) {
    switch (language) {
      case SupportedLanguage.esMX:
        return 'Claro. Dijiste: $userText';
      case SupportedLanguage.frCA:
        return 'Bien sur. Vous avez dit : $userText';
      case SupportedLanguage.enUS:
        return 'Sure. You said: $userText';
    }
  }

  String _defaultFallback(SupportedLanguage language) {
    switch (language) {
      case SupportedLanguage.esMX:
        return 'No entendi bien. Puedes repetirlo?';
      case SupportedLanguage.frCA:
        return 'Je n ai pas bien compris. Pouvez-vous reformuler?';
      case SupportedLanguage.enUS:
        return 'I did not catch that. Could you rephrase?';
    }
  }

  _Candidate _rank(List<_Candidate> candidates, String? lastResponse) {
    var best = candidates.first;
    var bestScore = _scoreCandidate(best, lastResponse);

    for (var i = 1; i < candidates.length; i++) {
      final score = _scoreCandidate(candidates[i], lastResponse);
      if (score > bestScore) {
        best = candidates[i];
        bestScore = score;
      }
    }

    return best;
  }

  double _scoreCandidate(_Candidate candidate, String? lastResponse) {
    var score = candidate.weight;
    if (lastResponse != null && lastResponse == candidate.text) {
      score -= repeatPenalty;
    }
    score += _random.nextDouble() * 0.05;
    return score;
  }
}

class _Candidate {
  const _Candidate({required this.text, required this.weight});

  final String text;
  final double weight;
}

class AgentResponse {
  const AgentResponse({
    required this.text,
    required this.intent,
    required this.confidence,
    required this.slots,
    required this.slotTags,
  });

  final String text;
  final String intent;
  final double confidence;
  final Map<String, String> slots;
  final List<String> slotTags;
}
