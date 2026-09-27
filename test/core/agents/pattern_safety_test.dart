import 'package:domovoy/core/agents/agents.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('bounded regex subset', () {
    test('accepts ordinary safe patterns', () {
      const safe = <String>[
        r'^[a-z]+$',
        r'^\d{4}-\d{2}-\d{2}$',
        r'^(?:foo|bar)$',
        r'^\s*\d+$',
        r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z',
        r'^[^,]*,[^,]*$',
        r'^a{2,5}b$',
        r'^a+?b$',
        r'\w+@\w+\.\w+',
        r'^[A-Za-z0-9_-]{1,64}$',
        r'^\d+\.\d+$|^\d+$',
        r'^[a-z]+\.[a-z]+$',
        r'^\d+-\d+-\d+-x$',
      ];
      for (final pattern in safe) {
        expect(toolPatternProblem(pattern), isNull, reason: pattern);
      }
    });

    test('rejects constructs whose work cannot be bounded', () {
      final unsafe = <String, String>{
        // The reported ReDoS repro: a quantified group with an inner
        // quantifier.
        r'(a+)+$': 'group',
        r'^(?:ab)+$': 'group',
        r'(a|b)+$': 'group',
        r'a*a*b': 'overlapping',
        r'.*.*': 'overlapping',
        r'\d+\d+': 'overlapping',
        r'(?=x)': 'group',
        r'(?!x)': 'group',
        r'(?<=x)y': 'group',
        r'(?<!x)y': 'group',
        r'(?<name>x)': 'group',
        r'(?i)abc': 'group',
        r'(a)\1': 'backreference',
        r'\p{L}': 'Unicode',
        r'a{1001}': 'exceeds',
        r'a*b*c*d*e*': 'unbounded',
        r'a?b?c?d?e?': 'ambiguous',
      };
      unsafe.forEach((pattern, expected) {
        final problem = toolPatternProblem(pattern);
        expect(problem, isNotNull, reason: pattern);
        expect(problem, contains(expected), reason: pattern);
      });
    });

    test('rejects oversized patterns and malformed groups quickly', () {
      final long = 'a' * (maxToolPatternLength + 1);
      expect(toolPatternProblem(long), contains('longer than'));
      expect(toolPatternProblem('(abc'), isNotNull);
      expect(toolPatternProblem('abc)'), isNotNull);
      expect(toolPatternProblem('a{3,1}'), isNotNull);
    });

    test('keeps the analyzer itself linear on hostile inputs', () {
      final stopwatch = Stopwatch()..start();
      // 5000 nested-looking groups hit the depth limit instead of recursing.
      final deep = '${'(' * 4000}a${')' * 4000}';
      expect(toolPatternProblem(deep), isNotNull);
      final wide = '${'a*' * 2000}b';
      expect(toolPatternProblem(wide), isNotNull);
      stopwatch.stop();
      expect(stopwatch.elapsedMilliseconds, lessThan(1000));
    });
  });
}
