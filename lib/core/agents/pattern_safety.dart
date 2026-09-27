/// Conservative static analysis of regular expressions from untrusted MCP
/// schemas.
///
/// Dart's `RegExp` is a backtracking engine: a crafted pattern and input can
/// take effectively unbounded time, and because matching is synchronous a
/// timeout on the same isolate cannot interrupt it. Instead of running
/// unknown patterns, [toolPatternProblem] accepts only patterns whose
/// matching work is provably bounded:
///
/// - no quantified groups (`(a+)+`), no nested quantifiers, no backreferences,
///   no lookarounds, no inline flags, no named groups;
/// - repetition bounds are explicit and small (`{n}`/`{n,m}`, `n,m` limited by
///   [maxToolPatternRepeat]);
/// - within one unseparated segment, ambiguous repetitions must have
///   pairwise disjoint character sets, at most
///   [maxToolPatternAmbiguousPerSegment] of them, at most
///   [maxToolPatternUnboundedPerSegment] unbounded, and their bounded choice
///   product must stay under [maxToolPatternAmbiguityFactor];
/// - the whole pattern is limited to [maxToolPatternLength] characters.
///
/// Anything outside the subset is reported with a reason, so the tool is
/// marked unavailable instead of being matched. The subset is deliberately
/// conservative: common anchored patterns, character classes and disjoint
/// quantifiers such as `^\s*\d+$`, `^[^,]*,[^,]*$` or `\d{4}-\d{2}-\d{2}`
/// stay supported, while quantified groups (for example `(?:ab)+`) and
/// overlapping repetitions (`a*a*`) do not.
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
  return _PatternParser(pattern).analyse();
}

final class _PatternParser {
  _PatternParser(this.source);

  final String source;
  var _index = 0;
  String? _problem;

  String? analyse() {
    _parseAlternation(depth: 0);
    if (_problem != null) {
      return _problem;
    }
    if (_index != source.length) {
      return 'unexpected "${source[_index]}" at position $_index.';
    }
    return null;
  }

  _Summary _parseAlternation({required int depth}) {
    final branches = <_Summary>[_parseSequence(depth: depth)];
    while (_problem == null && _peek() == '|') {
      _index += 1;
      branches.add(_parseSequence(depth: depth));
    }
    return _Summary.union(branches);
  }

  _Summary _parseSequence({required int depth}) {
    final state = _SegmentState();
    var charset = _CharSet.empty;
    var minLength = 0;
    var hasAmbiguity = false;
    final ambiguousClasses = <_CharSet>[];
    while (_problem == null) {
      final char = _peek();
      if (char == null || char == '|' || char == ')') {
        break;
      }
      if (char == '^' || char == r'$') {
        _index += 1;
        continue;
      }
      final start = _index;
      final atom = _parseAtom(depth: depth);
      if (_problem != null) {
        break;
      }
      if (atom is _GroupAtom && _startsQuantifier(_peek())) {
        _problem =
            'quantified groups are not supported (group at position $start).';
        break;
      }
      final quantifier = _parseQuantifier();
      if (_problem != null) {
        break;
      }
      final ambiguous = quantifier?.isAmbiguous ?? false;
      if (quantifier != null) {
        if (atom.charset.isEmpty) {
          _problem =
              'a quantifier at position $start is applied to a zero-width '
              'atom.';
          break;
        }
        _recordAmbiguous(
          state,
          atom.charset,
          unbounded: quantifier.isUnbounded,
          factor: quantifier.factor,
        );
        if (_problem != null) {
          break;
        }
      } else if (atom is _GroupAtom && atom.summary.hasAmbiguity) {
        final competition = atom.summary.ambiguousClasses.any(
          (ambiguousClass) => state.classes.any(ambiguousClass.intersects),
        );
        if (competition) {
          _problem =
              'an ambiguous repetition inside the group at position $start '
              'competes with a surrounding repetition.';
          break;
        }
        if (atom.summary.minLength > 0 &&
            _isSeparator(atom.charset, state.classes)) {
          state.reset();
        }
        for (final ambiguousClass in atom.summary.ambiguousClasses) {
          state.classes.add(ambiguousClass);
        }
        state.ambiguousCount += 1;
        if (state.ambiguousCount > maxToolPatternAmbiguousPerSegment) {
          _problem =
              'too many ambiguous repetitions in one segment around position '
              '$start.';
          break;
        }
      } else if (atom is _SetAtom) {
        _applyMandatory(state, atom.charset);
      } else if (atom.minLength > 0 &&
          _isSeparator(atom.charset, state.classes)) {
        state.reset();
      }
      charset = charset.union(atom.charset);
      minLength += atom.minLength * (quantifier?.minimumCount ?? 1);
      hasAmbiguity = hasAmbiguity || ambiguous || atom.isAmbiguous;
      if (ambiguous) {
        ambiguousClasses.add(atom.charset);
      } else if (atom is _GroupAtom) {
        ambiguousClasses.addAll(atom.summary.ambiguousClasses);
      }
    }
    return _Summary(
      charset: charset,
      minLength: minLength,
      hasAmbiguity: hasAmbiguity,
      ambiguousClasses: ambiguousClasses,
    );
  }

  _Atom _parseAtom({required int depth}) {
    final char = _peek();
    if (char == null) {
      _problem = 'unexpected end of pattern.';
      return const _AnchorAtom();
    }
    switch (char) {
      case '(':
        return _parseGroup(depth: depth);
      case '[':
        return _SetAtom(_parseCharClass());
      case '.':
        _index += 1;
        return _SetAtom(_CharSet.all);
      case r'\':
        return _parseEscape();
      case '*' || '+' || '?':
        _problem = 'quantifier "$char" at position $_index has no atom.';
        return const _AnchorAtom();
      default:
        _index += 1;
        return _SetAtom(_CharSet.literal(char.codeUnitAt(0)));
    }
  }

  _Atom _parseGroup({required int depth}) {
    final start = _index;
    if (depth >= 16) {
      _problem = 'groups are nested deeper than 16 levels at position $start.';
      return const _AnchorAtom();
    }
    _index += 1;
    if (_peek() == '?') {
      if (_peekAt(1) != ':') {
        _problem =
            'only non-capturing "(?:" groups are supported (position $start).';
        return const _AnchorAtom();
      }
      _index += 2;
    }
    final summary = _parseAlternation(depth: depth + 1);
    if (_problem != null) {
      return const _AnchorAtom();
    }
    if (_peek() != ')') {
      _problem = 'group at position $start is not closed.';
      return const _AnchorAtom();
    }
    _index += 1;
    return _GroupAtom(summary);
  }

  _Atom _parseEscape() {
    final start = _index;
    _index += 1;
    final char = _peek();
    if (char == null) {
      _problem = 'pattern ends with a backslash at position $start.';
      return const _AnchorAtom();
    }
    if (char == 'b' || char == 'B') {
      _index += 1;
      return const _AnchorAtom();
    }
    if (char == 'k' || _isDigit(char)) {
      _problem = 'backreferences are not supported (position $start).';
      return const _AnchorAtom();
    }
    if (char == 'p' || char == 'P') {
      _problem =
          'Unicode property escapes are not supported (position $start).';
      return const _AnchorAtom();
    }
    final escaped = _parseEscapeCharSet();
    if (_problem != null) {
      return const _AnchorAtom();
    }
    return _SetAtom(escaped);
  }

  _CharSet _parseEscapeCharSet() {
    final char = _peek()!;
    _index += 1;
    switch (char) {
      case 'd':
        return _CharSet.digit;
      case 'D':
        return _CharSet.digit.complement();
      case 'w':
        return _CharSet.word;
      case 'W':
        return _CharSet.word.complement();
      case 's':
        return _CharSet.space;
      case 'S':
        return _CharSet.space.complement();
      case 'n':
        return _CharSet.literal(0x0A);
      case 'r':
        return _CharSet.literal(0x0D);
      case 't':
        return _CharSet.literal(0x09);
      case 'f':
        return _CharSet.literal(0x0C);
      case 'v':
        return _CharSet.literal(0x0B);
      case '0':
        return _CharSet.literal(0x00);
      case 'x':
        return _CharSet.literal(_readHexEscape(2, fallback: 0x78));
      case 'u':
        if (_peek() == '{') {
          _problem = 'Unicode code point escapes are not supported.';
          return _CharSet.empty;
        }
        return _CharSet.literal(_readHexEscape(4, fallback: 0x75));
      default:
        return _CharSet.literal(char.codeUnitAt(0));
    }
  }

  int _readHexEscape(int digits, {required int fallback}) {
    final buffer = StringBuffer();
    for (var count = 0; count < digits; count += 1) {
      final char = _peek();
      if (char == null || !_isHexDigit(char)) {
        return fallback;
      }
      buffer.write(char);
      _index += 1;
    }
    return int.parse(buffer.toString(), radix: 16);
  }

  _CharSet _parseCharClass() {
    final start = _index;
    _index += 1;
    var negated = false;
    if (_peek() == '^') {
      negated = true;
      _index += 1;
    }
    var members = _CharSet.empty;
    var first = true;
    while (_problem == null) {
      final char = _peek();
      if (char == null) {
        _problem = 'character class at position $start is not closed.';
        return _CharSet.empty;
      }
      if (char == ']' && !first) {
        _index += 1;
        break;
      }
      first = false;
      if (_index - start > 256) {
        _problem = 'character class at position $start is too large.';
        return _CharSet.empty;
      }
      if (char == ']') {
        // A leading ']' is a literal member.
        _index += 1;
        members = members.union(_CharSet.literal(0x5D));
        continue;
      }
      if (char == r'\') {
        _index += 1;
        final escaped = _peek();
        if (escaped == null) {
          _problem =
              'character class at position $start ends with a '
              'backslash.';
          return _CharSet.empty;
        }
        if (_isClassEscape(escaped)) {
          _index += 1;
          members = members.union(_classEscapeSet(escaped));
          continue;
        }
        final firstChar = _parseClassLiteral(escaped, start);
        if (_problem != null) {
          return _CharSet.empty;
        }
        final range = _tryClassRange(firstChar, start);
        if (_problem != null) {
          return _CharSet.empty;
        }
        members = members.union(range ?? _CharSet.literal(firstChar));
        continue;
      }
      _index += 1;
      final firstChar = char.codeUnitAt(0);
      final range = _tryClassRange(firstChar, start);
      if (_problem != null) {
        return _CharSet.empty;
      }
      members = members.union(range ?? _CharSet.literal(firstChar));
    }
    return negated ? members.complement() : members;
  }

  int _parseClassLiteral(String escaped, int start) {
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
    if (_peek() != '-' || _peekAt(1) == null || _peekAt(1) == ']') {
      return null;
    }
    _index += 1;
    final char = _peek()!;
    late final int lastChar;
    if (char == r'\') {
      _index += 1;
      final escaped = _peek();
      if (escaped == null || _isClassEscape(escaped)) {
        _problem = 'character class at position $start has an invalid range.';
        return null;
      }
      lastChar = _parseClassLiteral(escaped, start);
    } else {
      _index += 1;
      lastChar = char.codeUnitAt(0);
    }
    if (lastChar < firstChar) {
      _problem = 'character class at position $start has a reversed range.';
      return null;
    }
    return _CharSet.range(firstChar, lastChar);
  }

  _Quantifier? _parseQuantifier() {
    final char = _peek();
    if (char == null) {
      return null;
    }
    switch (char) {
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
    if (_peek() == ',') {
      _index += 1;
      if (_peek() == '}') {
        unbounded = true;
      } else {
        final parsed = _readRepeatCount();
        if (parsed == null) {
          _problem = 'malformed repetition at position $start.';
          return null;
        }
        maximum = parsed;
      }
    }
    if (_peek() != '}') {
      _problem = 'malformed repetition at position $start.';
      return null;
    }
    _index += 1;
    if (maximum < minimum) {
      _problem = 'repetition at position $start has a reversed range.';
      return null;
    }
    if (maximum > maxToolPatternRepeat) {
      _problem = 'repetition at position $start exceeds $maxToolPatternRepeat.';
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
    while (true) {
      final char = _peek();
      if (char == null || !_isDigit(char)) {
        break;
      }
      value = value * 10 + (char.codeUnitAt(0) - 0x30);
      _index += 1;
      if (value > maxToolPatternRepeat) {
        return maxToolPatternRepeat + 1;
      }
    }
    if (_index == start) {
      return null;
    }
    return value;
  }

  void _consumeLazyMarker() {
    if (_peek() == '?') {
      _index += 1;
    }
  }

  void _recordAmbiguous(
    _SegmentState state,
    _CharSet charset, {
    required bool unbounded,
    required int factor,
  }) {
    for (final existing in state.classes) {
      if (existing.intersects(charset)) {
        _problem =
            'repetitions with overlapping character sets are not supported '
            '(position $_index).';
        return;
      }
    }
    state.classes.add(charset);
    state.ambiguousCount += 1;
    if (state.ambiguousCount > maxToolPatternAmbiguousPerSegment) {
      _problem =
          'more than $maxToolPatternAmbiguousPerSegment ambiguous repetitions '
          'are adjacent (position $_index).';
      return;
    }
    if (unbounded) {
      state.unboundedCount += 1;
      if (state.unboundedCount > maxToolPatternUnboundedPerSegment) {
        _problem =
            'more than $maxToolPatternUnboundedPerSegment unbounded '
            'repetitions are adjacent (position $_index).';
      }
      return;
    }
    state.factor *= factor;
    if (state.factor > maxToolPatternAmbiguityFactor) {
      _problem =
          'the number of ambiguous repetition choices exceeds '
          '$maxToolPatternAmbiguityFactor (position $_index).';
    }
  }

  void _applyMandatory(_SegmentState state, _CharSet charset) {
    if (state.classes.isEmpty) {
      return;
    }
    if (_isSeparator(charset, state.classes)) {
      state.reset();
      return;
    }
    // The mandatory atom can consume a character an earlier ambiguous
    // repetition could also consume, so it does not reset the segment.
    state.classes.add(charset);
  }

  bool _isSeparator(_CharSet charset, List<_CharSet> classes) {
    if (charset.isEmpty) {
      return false;
    }
    for (final existing in classes) {
      if (existing.intersects(charset)) {
        return false;
      }
    }
    return true;
  }

  String? _peek() => _peekAt(0);

  String? _peekAt(int offset) {
    final index = _index + offset;
    if (index < 0 || index >= source.length) {
      return null;
    }
    return source[index];
  }

  bool _startsQuantifier(String? char) =>
      char == '*' || char == '+' || char == '?' || char == '{';

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

  bool get isAmbiguous => isUnbounded || factor > 1;
}

sealed class _Atom {
  const _Atom();

  _CharSet get charset;

  int get minLength;

  bool get isAmbiguous => false;
}

final class _SetAtom extends _Atom {
  const _SetAtom(this.charset);

  @override
  final _CharSet charset;

  @override
  int get minLength => 1;
}

final class _GroupAtom extends _Atom {
  const _GroupAtom(this.summary);

  final _Summary summary;

  @override
  _CharSet get charset => summary.charset;

  @override
  int get minLength => summary.minLength;

  @override
  bool get isAmbiguous => summary.hasAmbiguity;
}

final class _AnchorAtom extends _Atom {
  const _AnchorAtom();

  @override
  _CharSet get charset => _CharSet.empty;

  @override
  int get minLength => 0;
}

final class _Summary {
  const _Summary({
    required this.charset,
    required this.minLength,
    required this.hasAmbiguity,
    required this.ambiguousClasses,
  });

  factory _Summary.union(List<_Summary> branches) {
    var charset = _CharSet.empty;
    var minLength = 0;
    var hasAmbiguity = false;
    final ambiguousClasses = <_CharSet>[];
    for (var index = 0; index < branches.length; index += 1) {
      final branch = branches[index];
      charset = charset.union(branch.charset);
      minLength = index == 0
          ? branch.minLength
          : (branch.minLength < minLength ? branch.minLength : minLength);
      hasAmbiguity = hasAmbiguity || branch.hasAmbiguity;
      ambiguousClasses.addAll(branch.ambiguousClasses);
    }
    return _Summary(
      charset: charset,
      minLength: minLength,
      hasAmbiguity: hasAmbiguity,
      ambiguousClasses: ambiguousClasses,
    );
  }

  final _CharSet charset;
  final int minLength;
  final bool hasAmbiguity;
  final List<_CharSet> ambiguousClasses;
}

final class _SegmentState {
  final List<_CharSet> classes = <_CharSet>[];
  var factor = 1;
  var ambiguousCount = 0;
  var unboundedCount = 0;

  void reset() {
    classes.clear();
    factor = 1;
    ambiguousCount = 0;
    unboundedCount = 0;
  }
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
