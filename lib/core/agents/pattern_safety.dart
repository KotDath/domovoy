/// Conservative static analysis of regular expressions from untrusted MCP
/// schemas.
///
/// Dart's `RegExp` is a backtracking engine: a crafted pattern and input can
/// take effectively unbounded time, and because matching is synchronous a
/// timeout on the same isolate cannot interrupt it. This analyzer therefore
/// accepts only a flat, auditable subset whose matching work is provably
/// bounded:
///
/// - no groups and no alternation at all. Repeated overlapping alternation
///   such as `(a|aa)(a|aa)...` backtracks exponentially even without any
///   quantifier, so both `(`/`)` and `|` are rejected outright;
/// - no backreferences, lookarounds, inline flags or Unicode property
///   escapes (all of them require `(` or `\`);
/// - quantifiers apply to a single character atom only, with explicit bounds
///   no larger than [maxToolPatternRepeat];
/// - within one unseparated segment, ambiguous repetitions must have pairwise
///   disjoint character sets, at most [maxToolPatternAmbiguousPerSegment] of
///   them, at most [maxToolPatternUnboundedPerSegment] unbounded, and their
///   bounded choice product must stay under [maxToolPatternAmbiguityFactor];
/// - the whole pattern is limited to [maxToolPatternLength] characters.
///
/// Everything else makes the tool unavailable with a visible reason instead
/// of being matched. Ordinary flat patterns such as `^\s*\d+$`,
/// `^[^,]*,[^,]*$`, `\d{4}-\d{2}-\d{2}` or `^[a-z]+\.[a-z]+$` stay
/// supported; patterns that need grouping are a visible unavailability and
/// must be expressed differently in the server schema.
library;

/// Maximum accepted pattern length.
const maxToolPatternLength = 512;

/// Maximum accepted repetition bound in `{n}`, `{n,}` or `{n,m}`.
const maxToolPatternRepeat = 1000;

/// Maximum product of bounded ambiguous choices inside one segment.
const maxToolPatternAmbiguityFactor = 4096;

/// Maximum ambiguous repetitions in one unseparated segment.
const maxToolPatternAmbiguousPerSegment = 4;

/// Maximum unbounded repetitions (`*`, `+`, `{n,}`) in one segment.
const maxToolPatternUnboundedPerSegment = 2;

/// Returns `null` when [pattern] can be matched in bounded time, otherwise a
/// human-readable reason that can be shown as a tool unavailability.
String? toolPatternProblem(String pattern) {
  if (pattern.length > maxToolPatternLength) {
    return 'pattern is longer than $maxToolPatternLength characters.';
  }
  return _FlatPatternAnalyzer(pattern).analyse();
}

final class _FlatPatternAnalyzer {
  _FlatPatternAnalyzer(this.source);

  final String source;
  var _index = 0;
  final List<_CharSet> _classes = <_CharSet>[];
  var _factor = 1;
  var _ambiguousCount = 0;
  var _unboundedCount = 0;

  String? analyse() {
    while (_index < source.length) {
      final char = source[_index];
      if (char == '(' || char == ')' || char == '|') {
        return 'grouping and alternation are not supported (position '
            '$_index).';
      }
      if (char == '^' || char == r'$') {
        _index += 1;
        continue;
      }
      if (char == '*' || char == '+' || char == '?') {
        return 'quantifier "$char" at position $_index has no atom.';
      }
      final charset = _parseAtom();
      if (charset == null) {
        return _error;
      }
      final quantifier = _parseQuantifier();
      if (_error != null) {
        return _error;
      }
      if (quantifier != null) {
        if (charset.isEmpty) {
          return 'a quantifier at position $_index is applied to a '
              'zero-width atom.';
        }
        final problem = _recordAmbiguous(charset, quantifier);
        if (problem != null) {
          return problem;
        }
      } else {
        _applyMandatory(charset);
      }
    }
    return null;
  }

  /// Parses one character atom; `null` means [_error] is set.
  _CharSet? _parseAtom() {
    final char = source[_index];
    if (char == r'\') {
      return _parseEscape();
    }
    if (char == '[') {
      return _parseCharClass();
    }
    _index += 1;
    if (char == '.') {
      return _CharSet.all;
    }
    return _CharSet.literal(char.codeUnitAt(0));
  }

  _CharSet? _parseEscape() {
    final start = _index;
    _index += 1;
    if (_index >= source.length) {
      _error = 'pattern ends with a backslash at position $start.';
      return null;
    }
    final char = source[_index];
    if (char == 'b' || char == 'B') {
      _index += 1;
      return _CharSet.empty;
    }
    if (char == 'k' || _isDigit(char)) {
      _error = 'backreferences are not supported (position $start).';
      return null;
    }
    if (char == 'p' || char == 'P') {
      _error = 'Unicode property escapes are not supported (position $start).';
      return null;
    }
    return _parseEscapeCharSet();
  }

  _CharSet _parseEscapeCharSet() {
    final char = source[_index];
    _index += 1;
    return switch (char) {
      'd' => _CharSet.digit,
      'D' => _CharSet.digit.complement(),
      'w' => _CharSet.word,
      'W' => _CharSet.word.complement(),
      's' => _CharSet.space,
      'S' => _CharSet.space.complement(),
      'n' => _CharSet.literal(0x0A),
      'r' => _CharSet.literal(0x0D),
      't' => _CharSet.literal(0x09),
      'f' => _CharSet.literal(0x0C),
      'v' => _CharSet.literal(0x0B),
      '0' => _CharSet.literal(0x00),
      'x' => _CharSet.literal(_readHexEscape(2, fallback: 0x78)),
      'u' => _CharSet.literal(_readHexEscape(4, fallback: 0x75)),
      _ => _CharSet.literal(char.codeUnitAt(0)),
    };
  }

  int _readHexEscape(int digits, {required int fallback}) {
    final buffer = StringBuffer();
    for (var count = 0; count < digits; count += 1) {
      if (_index >= source.length || !_isHexDigit(source[_index])) {
        return fallback;
      }
      buffer.write(source[_index]);
      _index += 1;
    }
    return int.parse(buffer.toString(), radix: 16);
  }

  _CharSet? _parseCharClass() {
    final start = _index;
    _index += 1;
    var negated = false;
    if (_index < source.length && source[_index] == '^') {
      negated = true;
      _index += 1;
    }
    var members = _CharSet.empty;
    var first = true;
    while (true) {
      if (_index >= source.length) {
        _error = 'character class at position $start is not closed.';
        return null;
      }
      final char = source[_index];
      if (char == ']' && !first) {
        _index += 1;
        break;
      }
      first = false;
      if (_index - start > 256) {
        _error = 'character class at position $start is too large.';
        return null;
      }
      if (char == ']') {
        // A leading ']' is a literal member.
        _index += 1;
        members = members.union(_CharSet.literal(0x5D));
        continue;
      }
      if (char == r'\') {
        _index += 1;
        if (_index >= source.length) {
          _error = 'character class at position $start ends with a backslash.';
          return null;
        }
        final escaped = source[_index];
        if (_isClassEscape(escaped)) {
          _index += 1;
          members = members.union(_classEscapeSet(escaped));
          continue;
        }
        final codeUnit = _parseClassLiteral(escaped);
        final range = _tryClassRange(codeUnit, start);
        if (_error != null) {
          return null;
        }
        members = members.union(range ?? _CharSet.literal(codeUnit));
        continue;
      }
      _index += 1;
      final codeUnit = char.codeUnitAt(0);
      final range = _tryClassRange(codeUnit, start);
      if (_error != null) {
        return null;
      }
      members = members.union(range ?? _CharSet.literal(codeUnit));
    }
    return negated ? members.complement() : members;
  }

  int _parseClassLiteral(String escaped) {
    switch (escaped) {
      case 'n':
        _index += 1;
        return 0x0A;
      case 'r':
        _index += 1;
        return 0x0D;
      case 't':
        _index += 1;
        return 0x09;
      case 'f':
        _index += 1;
        return 0x0C;
      case 'v':
        _index += 1;
        return 0x0B;
      case '0':
        _index += 1;
        return 0x00;
      case 'x':
        _index += 1;
        return _readHexEscape(2, fallback: 0x78);
      case 'u':
        _index += 1;
        return _readHexEscape(4, fallback: 0x75);
      default:
        _index += 1;
        return escaped.codeUnitAt(0);
    }
  }

  _CharSet? _tryClassRange(int firstChar, int start) {
    if (_index + 1 >= source.length ||
        source[_index] != '-' ||
        source[_index + 1] == ']') {
      return null;
    }
    _index += 1;
    final char = source[_index];
    late final int lastChar;
    if (char == r'\') {
      _index += 1;
      if (_index >= source.length || _isClassEscape(source[_index])) {
        _error = 'character class at position $start has an invalid range.';
        return null;
      }
      lastChar = _parseClassLiteral(source[_index]);
    } else {
      _index += 1;
      lastChar = char.codeUnitAt(0);
    }
    if (lastChar < firstChar) {
      _error = 'character class at position $start has a reversed range.';
      return null;
    }
    return _CharSet.range(firstChar, lastChar);
  }

  _Quantifier? _parseQuantifier() {
    if (_index >= source.length) {
      return null;
    }
    switch (source[_index]) {
      case '*':
        _index += 1;
        _consumeLazyMarker();
        return const _Quantifier(minimumCount: 0, isUnbounded: true, factor: 1);
      case '+':
        _index += 1;
        _consumeLazyMarker();
        return const _Quantifier(minimumCount: 1, isUnbounded: true, factor: 1);
      case '?':
        _index += 1;
        _consumeLazyMarker();
        return const _Quantifier(
          minimumCount: 0,
          isUnbounded: false,
          factor: 2,
        );
      case '{':
        return _parseBracedQuantifier();
      default:
        return null;
    }
  }

  _Quantifier? _parseBracedQuantifier() {
    final start = _index;
    _index += 1;
    final minimum = _readRepeatCount();
    if (minimum == null) {
      _index = start;
      return null;
    }
    var maximum = minimum;
    var unbounded = false;
    if (_index < source.length && source[_index] == ',') {
      _index += 1;
      if (_index < source.length && source[_index] == '}') {
        unbounded = true;
      } else {
        final parsed = _readRepeatCount();
        if (parsed == null) {
          _error = 'malformed repetition at position $start.';
          return null;
        }
        maximum = parsed;
      }
    }
    if (_index >= source.length || source[_index] != '}') {
      _index = start;
      return null;
    }
    _index += 1;
    if (maximum < minimum) {
      _error = 'repetition at position $start has a reversed range.';
      return null;
    }
    if (maximum > maxToolPatternRepeat) {
      _error = 'repetition at position $start exceeds $maxToolPatternRepeat.';
      return null;
    }
    _consumeLazyMarker();
    final factor = unbounded || maximum == minimum
        ? 1
        : (maximum - minimum + 1);
    return _Quantifier(
      minimumCount: minimum,
      isUnbounded: unbounded,
      factor: factor,
    );
  }

  int? _readRepeatCount() {
    final start = _index;
    var value = 0;
    while (_index < source.length && _isDigit(source[_index])) {
      value = value * 10 + (source[_index].codeUnitAt(0) - 0x30);
      _index += 1;
      if (value > maxToolPatternRepeat) {
        return maxToolPatternRepeat + 1;
      }
    }
    return _index == start ? null : value;
  }

  void _consumeLazyMarker() {
    if (_index < source.length && source[_index] == '?') {
      _index += 1;
    }
  }

  String? _recordAmbiguous(_CharSet charset, _Quantifier quantifier) {
    for (final existing in _classes) {
      if (existing.intersects(charset)) {
        return 'repetitions with overlapping character sets are not '
            'supported (position $_index).';
      }
    }
    _classes.add(charset);
    _ambiguousCount += 1;
    if (_ambiguousCount > maxToolPatternAmbiguousPerSegment) {
      return 'more than $maxToolPatternAmbiguousPerSegment ambiguous '
          'repetitions are adjacent (position $_index).';
    }
    if (quantifier.isUnbounded) {
      _unboundedCount += 1;
      if (_unboundedCount > maxToolPatternUnboundedPerSegment) {
        return 'more than $maxToolPatternUnboundedPerSegment unbounded '
            'repetitions are adjacent (position $_index).';
      }
      return null;
    }
    _factor *= quantifier.factor;
    if (_factor > maxToolPatternAmbiguityFactor) {
      return 'the number of ambiguous repetition choices exceeds '
          '$maxToolPatternAmbiguityFactor (position $_index).';
    }
    return null;
  }

  void _applyMandatory(_CharSet charset) {
    if (_classes.isEmpty) {
      return;
    }
    if (_isSeparator(charset)) {
      _classes.clear();
      _factor = 1;
      _ambiguousCount = 0;
      _unboundedCount = 0;
      return;
    }
    // The mandatory atom can consume a character an earlier ambiguous
    // repetition could also consume, so it does not reset the segment.
    _classes.add(charset);
  }

  /// A non-empty mandatory atom consumed by a disjoint character set separates
  /// two ambiguous repetitions; an empty (zero-width) atom never does.
  bool _isSeparator(_CharSet charset) {
    if (charset.isEmpty) {
      return false;
    }
    for (final existing in _classes) {
      if (existing.intersects(charset)) {
        return false;
      }
    }
    return true;
  }

  bool _isDigit(String char) {
    final code = char.codeUnitAt(0);
    return code >= 0x30 && code <= 0x39;
  }

  bool _isHexDigit(String char) {
    final code = char.codeUnitAt(0);
    return (code >= 0x30 && code <= 0x39) ||
        (code >= 0x41 && code <= 0x46) ||
        (code >= 0x61 && code <= 0x66);
  }

  bool _isClassEscape(String char) =>
      char == 'd' ||
      char == 'D' ||
      char == 'w' ||
      char == 'W' ||
      char == 's' ||
      char == 'S';

  _CharSet _classEscapeSet(String char) => switch (char) {
    'd' => _CharSet.digit,
    'D' => _CharSet.digit.complement(),
    'w' => _CharSet.word,
    'W' => _CharSet.word.complement(),
    's' => _CharSet.space,
    _ => _CharSet.space.complement(),
  };

  String? _error;
}

final class _Quantifier {
  const _Quantifier({
    required this.minimumCount,
    required this.isUnbounded,
    required this.factor,
  });

  final int minimumCount;
  final bool isUnbounded;
  final int factor;
}

final class _Range {
  const _Range(this.low, this.high);

  final int low;
  final int high;
}

/// Immutable set of code units represented as normalised ranges.
final class _CharSet {
  _CharSet(List<_Range> ranges) : ranges = _normalise(ranges);

  static final empty = _CharSet(const <_Range>[]);
  static final all = _CharSet(const <_Range>[_Range(0, 0x10FFFF)]);
  static final digit = _CharSet(const <_Range>[_Range(0x30, 0x39)]);
  static final word = _CharSet(const <_Range>[
    _Range(0x30, 0x39),
    _Range(0x41, 0x5A),
    _Range(0x5F, 0x5F),
    _Range(0x61, 0x7A),
  ]);
  static final space = _CharSet(const <_Range>[
    _Range(0x09, 0x0D),
    _Range(0x20, 0x20),
    _Range(0xA0, 0xA0),
    _Range(0x1680, 0x1680),
    _Range(0x2000, 0x200A),
    _Range(0x2028, 0x2029),
    _Range(0x202F, 0x202F),
    _Range(0x205F, 0x205F),
    _Range(0x3000, 0x3000),
    _Range(0xFEFF, 0xFEFF),
  ]);

  final List<_Range> ranges;

  bool get isEmpty => ranges.isEmpty;

  static _CharSet literal(int codeUnit) =>
      _CharSet(<_Range>[_Range(codeUnit, codeUnit)]);

  static _CharSet range(int low, int high) =>
      _CharSet(<_Range>[_Range(low, high)]);

  _CharSet union(_CharSet other) =>
      _CharSet(<_Range>[...ranges, ...other.ranges]);

  _CharSet intersect(_CharSet other) {
    final result = <_Range>[];
    for (final left in ranges) {
      for (final right in other.ranges) {
        final low = left.low > right.low ? left.low : right.low;
        final high = left.high < right.high ? left.high : right.high;
        if (low <= high) {
          result.add(_Range(low, high));
        }
      }
    }
    return _CharSet(result);
  }

  bool intersects(_CharSet other) => !intersect(other).isEmpty;

  _CharSet complement() {
    final result = <_Range>[];
    var cursor = 0;
    for (final range in ranges) {
      if (range.low > cursor) {
        result.add(_Range(cursor, range.low - 1));
      }
      cursor = range.high + 1;
    }
    if (cursor <= 0x10FFFF) {
      result.add(_Range(cursor, 0x10FFFF));
    }
    return _CharSet(result);
  }

  static List<_Range> _normalise(List<_Range> source) {
    if (source.isEmpty) {
      return const <_Range>[];
    }
    final sorted = List<_Range>.of(source)
      ..sort((a, b) => a.low == b.low ? a.high - b.high : a.low - b.low);
    final merged = <_Range>[];
    var current = sorted.first;
    for (var index = 1; index < sorted.length; index += 1) {
      final next = sorted[index];
      if (next.low <= current.high + 1) {
        current = _Range(
          current.low,
          next.high > current.high ? next.high : current.high,
        );
        continue;
      }
      merged.add(current);
      current = next;
    }
    merged.add(current);
    return List<_Range>.unmodifiable(merged);
  }
}
