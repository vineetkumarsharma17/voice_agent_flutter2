import '../model_registry.dart';

class EntityExtractor {
  ExtractedEntities extract(String text, SupportedLanguage language) {
    final normalized = text.trim();
    final entities = <String, String>{};

    final email = _match(normalized, RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'));
    if (email != null) {
      entities['email'] = email;
    }

    final phone = _match(normalized, RegExp(r'(\+?\d[\d\s\-().]{7,})'));
    if (phone != null) {
      entities['phone'] = phone.replaceAll(RegExp(r'\s+'), ' ');
    }

    final amount = _match(normalized, RegExp(r'\$\s?\d+(?:[\.,]\d+)?'));
    if (amount != null) {
      entities['amount'] = amount;
    }

    final time = _match(normalized, RegExp(r'\b\d{1,2}:\d{2}\b'));
    if (time != null) {
      entities['time'] = time;
    }

    final name = _extractName(normalized, language);
    if (name != null) {
      entities['name'] = name;
    }

    return ExtractedEntities(entities);
  }

  String? _match(String text, RegExp pattern) {
    final match = pattern.firstMatch(text);
    if (match == null) return null;
    return match.group(0);
  }

  String? _extractName(String text, SupportedLanguage language) {
    switch (language) {
      case SupportedLanguage.esMX:
        return _match(text, RegExp(r'(?:me llamo|mi nombre es)\s+([A-Za-z]{2,})', caseSensitive: false))
            ?.split(' ')
            .last;
      case SupportedLanguage.frCA:
        return _match(text, RegExp(r"(?:je m'appelle|mon nom est)\s+([A-Za-z]{2,})", caseSensitive: false))
            ?.split(' ')
            .last;
      case SupportedLanguage.enUS:
        return _match(text, RegExp(r"(?:my name is|i am|i'm)\s+([A-Za-z]{2,})", caseSensitive: false))
            ?.split(' ')
            .last;
    }
  }
}

class ExtractedEntities {
  ExtractedEntities(this.values);

  final Map<String, String> values;

  bool get isEmpty => values.isEmpty;
}
