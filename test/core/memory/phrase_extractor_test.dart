import 'package:domovoy/core/memory/memory.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('explicit remember phrases', () {
    test('parses project, global, and default scopes', () {
      final proposals = parseMemoryRememberPhrases(
        'remember project: Deployment uses kubernetes.\n'
        'remember global: Prefers concise answers.\n'
        'remember: The sprint ends on Friday.',
      );
      expect(proposals, hasLength(3));
      expect(proposals[0].layer, MemoryLayer.working);
      expect(proposals[0].scope, MemoryScope.project);
      expect(proposals[0].kind, MemoryKind.fact);
      expect(proposals[0].content, 'Deployment uses kubernetes.');
      expect(proposals[1].layer, MemoryLayer.longTerm);
      expect(proposals[1].scope, MemoryScope.global);
      expect(proposals[2].layer, MemoryLayer.working);
      expect(proposals[2].scope, MemoryScope.project);
    });

    test('parses Russian phrases', () {
      final proposals = parseMemoryRememberPhrases(
        'запомни проект: Деплой идёт через kubernetes.\n'
        'запомни глобально: Предпочитает краткие ответы.',
      );
      expect(proposals, hasLength(2));
      expect(proposals[0].scope, MemoryScope.project);
      expect(proposals[1].scope, MemoryScope.global);
      expect(proposals[1].layer, MemoryLayer.longTerm);
    });

    test('parses natural remember-that phrases', () {
      final russian = parseMemoryRememberPhrases(
        'Запомни, что деплой делается только через kubernetes',
      );
      final english = parseMemoryRememberPhrases(
        'Remember globally that I prefer concise answers.',
      );

      expect(russian, hasLength(1));
      expect(russian.single.scope, MemoryScope.project);
      expect(russian.single.layer, MemoryLayer.working);
      expect(russian.single.content, 'деплой делается только через kubernetes');
      expect(english, hasLength(1));
      expect(english.single.scope, MemoryScope.global);
      expect(english.single.layer, MemoryLayer.longTerm);
      expect(english.single.content, 'I prefer concise answers.');
    });

    test('drops malformed and secret-bearing phrases', () {
      final proposals = parseMemoryRememberPhrases(
        'remember project:\n'
        'remember project: token: abcdefghij\n'
        'remember project: A valid fact.',
      );
      expect(proposals, hasLength(1));
      expect(proposals.single.content, 'A valid fact.');
    });

    test('ignores text without a phrase', () {
      expect(parseMemoryRememberPhrases('Just a normal message.'), isEmpty);
      expect(parseMemoryRememberPhrases(''), isEmpty);
    });
  });
}
