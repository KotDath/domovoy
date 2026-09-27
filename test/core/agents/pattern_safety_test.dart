import 'package:domovoy/core/agents/agents.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('bounded regex subset', () {
    test('accepts ordinary safe flat patterns', () {
      const safe = <String>[
        r'^[a-z]+$',
        r'^\d{4}-\d{2}-\d{2}$',
        r'^\s*\d+$',
        r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z',
        r'^[^,]*,[^,]*$',
        r'^a{2,5}b$',
        r'^a+?b$',
        r'\w+@\w+\.\w+',
        r'^[A-Za-z0-9_-]{1,64}$',
        r'^[a-z]+\.[a-z]+$',
        r'^\d+-\d+-\d+-x$',
      ];
      for (final pattern in safe) {
        expect(toolPatternProblem(pattern), isNull, reason: pattern);
      }
    });

    test('rejects the repeated-overlapping-alternation probe', () {
      // Even without any quantifier this backtracks exponentially; the
      // analyzer must reject it before anything tries to match it.
      final pattern = '^${'(a|aa)' * 24}b\$';
      expect(toolPatternProblem(pattern), isNotNull);
    });

    test('rejects grouping, alternation and other unsafe constructs', () {
      final unsafe = <String, String>{
        r'(a+)+$': 'grouping and alternation',
        r'^(?:ab)+$': 'grouping and alternation',
        r'(a|b)+$': 'grouping and alternation',
        r'^(?=x)y$': 'grouping and alternation',
        r'(?<=x)y': 'grouping and alternation',
        r'(?<name>x)': 'grouping and alternation',
        r'(?i)abc': 'grouping and alternation',
        r'a|b': 'grouping and alternation',
        r'^a|b$': 'grouping and alternation',
        r'a*a*b': 'overlapping',
        r'.*.*': 'overlapping',
        r'\d+\d+': 'overlapping',
        r'\1': 'backreference',
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

    test('rejects oversized and malformed patterns quickly', () {
      final long = 'a' * (maxToolPatternLength + 1);
      expect(toolPatternProblem(long), contains('longer than'));
      expect(toolPatternProblem('(abc'), isNotNull);
      expect(toolPatternProblem('abc)'), isNotNull);
      expect(toolPatternProblem('a{3,1}'), isNotNull);
    });

    test('keeps the analyzer itself linear on hostile inputs', () {
      final stopwatch = Stopwatch()..start();
      // Thousands of group openers are rejected on the first one.
      final deep = '${'(' * 4000}a${')' * 4000}';
      expect(toolPatternProblem(deep), isNotNull);
      final wide = '${'a*' * 2000}b';
      expect(toolPatternProblem(wide), isNotNull);
      stopwatch.stop();
      expect(stopwatch.elapsedMilliseconds, lessThan(1000));
    });
  });
}
