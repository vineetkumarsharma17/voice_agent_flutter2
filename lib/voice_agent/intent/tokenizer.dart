class WordPieceTokenizer {
  WordPieceTokenizer(this.vocab, {required this.doLowerCase})
      : _vocabMap = _buildVocabMap(vocab);

  final List<String> vocab;
  final bool doLowerCase;
  final Map<String, int> _vocabMap;

  static Map<String, int> _buildVocabMap(List<String> vocab) {
    final map = <String, int>{};
    for (var i = 0; i < vocab.length; i++) {
      map[vocab[i]] = i;
    }
    return map;
  }

  TokenizedInput encode(String text, int maxLen) {
    final tokens = <String>[];
    tokens.add('[CLS]');

    final basicTokens = _basicTokenize(text);
    for (final token in basicTokens) {
      tokens.addAll(_wordPieceTokenize(token));
    }

    tokens.add('[SEP]');

    if (tokens.length > maxLen) {
      tokens
        ..removeRange(maxLen - 1, tokens.length)
        ..add('[SEP]');
    }

    final inputIds = List<int>.filled(maxLen, 0);
    final attentionMask = List<int>.filled(maxLen, 0);
    final tokenTypeIds = List<int>.filled(maxLen, 0);

    for (var i = 0; i < tokens.length && i < maxLen; i++) {
      final token = tokens[i];
      final id = _vocabMap[token] ?? _vocabMap['[UNK]'] ?? 0;
      inputIds[i] = id;
      attentionMask[i] = 1;
    }

    return TokenizedInput(
      inputIds: inputIds,
      attentionMask: attentionMask,
      tokenTypeIds: tokenTypeIds,
      tokens: tokens,
    );
  }

  List<String> _basicTokenize(String text) {
    var normalized = text.trim();
    if (doLowerCase) {
      normalized = normalized.toLowerCase();
    }

    final tokens = <String>[];
    final buffer = StringBuffer();

    void flush() {
      if (buffer.isNotEmpty) {
        tokens.add(buffer.toString());
        buffer.clear();
      }
    }

    for (final rune in normalized.runes) {
      final ch = String.fromCharCode(rune);
      if (_isWhitespace(ch)) {
        flush();
      } else if (_isPunctuation(ch)) {
        flush();
        tokens.add(ch);
      } else {
        buffer.write(ch);
      }
    }
    flush();

    return tokens;
  }

  List<String> _wordPieceTokenize(String token) {
    if (_vocabMap.containsKey(token)) {
      return [token];
    }

    const maxInputCharsPerWord = 100;
    if (token.length > maxInputCharsPerWord) {
      return ['[UNK]'];
    }

    final subTokens = <String>[];
    var start = 0;
    var isBad = false;

    while (start < token.length) {
      var end = token.length;
      String? curSubstr;
      while (start < end) {
        var substr = token.substring(start, end);
        if (start > 0) {
          substr = '##$substr';
        }
        if (_vocabMap.containsKey(substr)) {
          curSubstr = substr;
          break;
        }
        end -= 1;
      }

      if (curSubstr == null) {
        isBad = true;
        break;
      }

      subTokens.add(curSubstr);
      start = end;
    }

    if (isBad) {
      return ['[UNK]'];
    }

    return subTokens;
  }

  bool _isWhitespace(String ch) {
    return ch == ' ' || ch == '\n' || ch == '\t' || ch == '\r';
  }

  bool _isPunctuation(String ch) {
    const punctuation = '!"#\$%&\'()*+,-./:;<=>?@[\\]^_`{|}~';
    return punctuation.contains(ch);
  }
}

class TokenizedInput {
  const TokenizedInput({
    required this.inputIds,
    required this.attentionMask,
    required this.tokenTypeIds,
    required this.tokens,
  });

  final List<int> inputIds;
  final List<int> attentionMask;
  final List<int> tokenTypeIds;
  final List<String> tokens;
}
