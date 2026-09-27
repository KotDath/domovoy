import 'errors.dart';
import 'time_zones.dart';
import 'wall_clock.dart';

/// Conventional five-field cron expression: minutes, hours, day of month,
/// month, day of week.
///
/// Supported per field: `*`, lists (`1,5`), ranges (`1-5`), steps (`*/5`,
/// `1-30/10`, `5/15`), month names (`JAN`..`DEC`) and weekday names
/// (`SUN`..`SAT`). Seconds, Quartz macros (`@daily`), `?`, `L`, `W` and `#`
/// are rejected with a visible error.
///
/// Day-of-month/day-of-week interaction follows the conventional (Vixie cron)
/// rule: when **both** fields are restricted, a date matches when **either**
/// matches; when only one is restricted, only that one is used. A field is
/// "restricted" when it is not exactly `*`.
///
/// The search for the next (or previous) occurrence is bounded: it walks whole
/// calendar days for at most [maxLookaheadDays] days. An expression that can
/// never fire (for example `0 0 30 2 *`) returns `null` instead of looping.
final class CronExpression {
  CronExpression._(
    this.expression,
    this._minutes,
    this._hours,
    this._daysOfMonth,
    this._months,
    this._daysOfWeek,
  );

  /// Parses a five-field cron expression.
  ///
  /// Throws [AutomationException] with [AutomationErrorKind.invalidSchedule]
  /// and a message naming the offending field.
  static CronExpression parse(String raw) {
    final normalized = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.isEmpty) {
      throwAutomation(
        AutomationErrorKind.invalidSchedule,
        'Cron-выражение не задано.',
      );
    }
    final parts = normalized.split(' ');
    if (parts.length != 5) {
      throwAutomation(
        AutomationErrorKind.invalidSchedule,
        'Нужно пять полей «минуты часы день_месяца месяц день_недели»; '
        'получено ${parts.length}. Секунды и Quartz-макросы не поддерживаются.',
      );
    }
    return CronExpression._(
      normalized,
      _CronField.parse(label: 'Минуты', raw: parts[0], min: 0, max: 59),
      _CronField.parse(label: 'Часы', raw: parts[1], min: 0, max: 23),
      _CronField.parse(label: 'День месяца', raw: parts[2], min: 1, max: 31),
      _CronField.parse(
        label: 'Месяц',
        raw: parts[3],
        min: 1,
        max: 12,
        aliases: _monthAliases,
      ),
      _CronField.parse(
        label: 'День недели',
        raw: parts[4],
        min: 0,
        max: 7,
        aliases: _weekdayAliases,
        // 0 and 7 are both Sunday in conventional cron.
        normalize: (value) => value == 7 ? 0 : value,
      ),
    );
  }

  /// Whether [raw] parses as a five-field expression.
  static bool isValid(String raw) {
    try {
      parse(raw);
      return true;
    } on AutomationException {
      return false;
    }
  }

  /// Largest number of calendar days the occurrence search walks before giving
  /// up. Twelve years plus the leap-day offset always contains at least three
  /// occurrences of any reachable five-field expression (29 February recurs at
  /// most every eight years), so a `null` result means the expression can
  /// never fire.
  static const maxLookaheadDays = 366 * 12 + 3;

  final String expression;
  final _CronField _minutes;
  final _CronField _hours;
  final _CronField _daysOfMonth;
  final _CronField _months;
  final _CronField _daysOfWeek;

  /// True when the day-of-month field is not exactly `*`.
  bool get restrictsDayOfMonth => !_daysOfMonth.isWildcard;

  /// True when the day-of-week field is not exactly `*`.
  bool get restrictsDayOfWeek => !_daysOfWeek.isWildcard;

  /// True when both day fields are restricted and conventional OR applies.
  bool get usesEitherDayField => restrictsDayOfMonth && restrictsDayOfWeek;

  /// Whether the date part of [date] matches this expression.
  bool matchesDate(DateTime date) {
    if (!_months.matches(date.month)) {
      return false;
    }
    final dayOfMonth = _daysOfMonth.matches(date.day);
    final dayOfWeek = _daysOfWeek.matches(date.weekday % 7);
    if (!restrictsDayOfMonth && !restrictsDayOfWeek) {
      return true;
    }
    if (!restrictsDayOfMonth) {
      return dayOfWeek;
    }
    if (!restrictsDayOfWeek) {
      return dayOfMonth;
    }
    return dayOfMonth || dayOfWeek;
  }

  /// Whether the minute/hour/date fields all match [wallClock].
  bool matchesWallClock(WallClockTime wallClock) {
    if (!_minutes.matches(wallClock.minute) ||
        !_hours.matches(wallClock.hour)) {
      return false;
    }
    final date = DateTime.utc(wallClock.year, wallClock.month, wallClock.day);
    return matchesDate(date);
  }

  /// Next occurrence strictly after [afterUtc], or null when none exists
  /// within [maxLookaheadDays] days.
  ///
  /// A wall-clock reading that does not exist because of a spring-forward gap
  /// is skipped. A reading that happens twice because of an autumn fold fires
  /// once, at the **earlier** UTC instant.
  DateTime? nextAfter({
    required DateTime afterUtc,
    required String timeZoneId,
    required AutomationTimeZones zones,
  }) {
    var wall = zones.localTime(timeZoneId, afterUtc.toUtc()).addMinutes(1);
    var daysRemaining = maxLookaheadDays;
    while (daysRemaining > 0) {
      if (!_matchesDayFields(wall)) {
        wall = wall.nextDayStart;
        daysRemaining -= 1;
        continue;
      }
      final candidate = _firstAllowedAtOrAfter(wall);
      if (candidate == null) {
        wall = wall.nextDayStart;
        daysRemaining -= 1;
        continue;
      }
      final instants = zones.resolveLocal(timeZoneId, candidate);
      if (instants.isEmpty) {
        // Spring-forward gap: this local reading never happens today.
        wall = candidate.addMinutes(1);
        continue;
      }
      final instant = instants.first;
      if (instant.isAfter(afterUtc)) {
        return instant;
      }
      wall = candidate.addMinutes(1);
    }
    return null;
  }

  /// Up to [count] occurrences strictly after [afterUtc].
  ///
  /// Returns fewer entries when the expression runs out of occurrences inside
  /// the bounded horizon.
  List<DateTime> nextOccurrences({
    required DateTime afterUtc,
    required String timeZoneId,
    required AutomationTimeZones zones,
    int count = 3,
  }) {
    if (count <= 0) {
      return const <DateTime>[];
    }
    final results = <DateTime>[];
    var cursor = afterUtc.toUtc();
    for (var index = 0; index < count; index += 1) {
      final next = nextAfter(
        afterUtc: cursor,
        timeZoneId: timeZoneId,
        zones: zones,
      );
      if (next == null) {
        break;
      }
      results.add(next);
      cursor = next;
    }
    return List<DateTime>.unmodifiable(results);
  }

  /// Latest occurrence at or before [boundUtc], or null when there is none
  /// inside the bounded horizon.
  DateTime? lastAtOrBefore({
    required DateTime boundUtc,
    required String timeZoneId,
    required AutomationTimeZones zones,
  }) {
    var wall = zones.localTime(timeZoneId, boundUtc.toUtc());
    var daysRemaining = maxLookaheadDays;
    while (daysRemaining > 0) {
      if (!_matchesDayFields(wall)) {
        wall = _previousDayEnd(wall);
        daysRemaining -= 1;
        continue;
      }
      final candidate = _lastAllowedAtOrBefore(wall);
      if (candidate == null) {
        wall = _previousDayEnd(wall);
        daysRemaining -= 1;
        continue;
      }
      final instants = zones.resolveLocal(timeZoneId, candidate);
      if (instants.isEmpty) {
        wall = candidate.addMinutes(-1);
        continue;
      }
      final instant = instants.first;
      if (!instant.isAfter(boundUtc)) {
        return instant;
      }
      wall = candidate.addMinutes(-1);
    }
    return null;
  }

  /// Verifies that the expression can fire at all and that the first three
  /// occurrences exist. Used when a task is saved, so an impossible date such
  /// as `0 0 30 2 *` is rejected instead of silently never firing.
  void validateReachable({
    required String timeZoneId,
    required AutomationTimeZones zones,
  }) {
    final probe = DateTime.utc(2024, 1, 1);
    final occurrences = nextOccurrences(
      afterUtc: probe,
      timeZoneId: timeZoneId,
      zones: zones,
      count: 3,
    );
    if (occurrences.length < 3) {
      throwAutomation(
        AutomationErrorKind.invalidSchedule,
        'Выражение "$expression" никогда не сработает в часовом поясе '
        '"$timeZoneId" (например, такой даты не существует).',
      );
    }
  }

  bool _matchesDayFields(WallClockTime wall) {
    if (!_months.matches(wall.month)) {
      return false;
    }
    return matchesDate(DateTime.utc(wall.year, wall.month, wall.day));
  }

  /// First allowed minute at or after [from] on the same calendar day.
  WallClockTime? _firstAllowedAtOrAfter(WallClockTime from) {
    for (final hour in _hours.sorted) {
      if (hour < from.hour) {
        continue;
      }
      if (hour > from.hour) {
        return WallClockTime(
          from.year,
          from.month,
          from.day,
          hour,
          _minutes.sorted.first,
        );
      }
      for (final minute in _minutes.sorted) {
        if (minute >= from.minute) {
          return WallClockTime(from.year, from.month, from.day, hour, minute);
        }
      }
    }
    return null;
  }

  /// Last allowed minute at or before [from] on the same calendar day.
  WallClockTime? _lastAllowedAtOrBefore(WallClockTime from) {
    final hours = _hours.sorted;
    for (var index = hours.length - 1; index >= 0; index -= 1) {
      final hour = hours[index];
      if (hour > from.hour) {
        continue;
      }
      if (hour < from.hour) {
        return WallClockTime(
          from.year,
          from.month,
          from.day,
          hour,
          _minutes.sorted.last,
        );
      }
      final minutes = _minutes.sorted;
      for (
        var minuteIndex = minutes.length - 1;
        minuteIndex >= 0;
        minuteIndex -= 1
      ) {
        final minute = minutes[minuteIndex];
        if (minute <= from.minute) {
          return WallClockTime(from.year, from.month, from.day, hour, minute);
        }
      }
    }
    return null;
  }

  WallClockTime _previousDayEnd(WallClockTime wall) {
    final previousDay = DateTime.utc(
      wall.year,
      wall.month,
      wall.day,
    ).subtract(const Duration(days: 1));
    return WallClockTime(
      previousDay.year,
      previousDay.month,
      previousDay.day,
      23,
      59,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CronExpression && other.expression == expression;

  @override
  int get hashCode => expression.hashCode;

  @override
  String toString() => expression;
}

/// One parsed cron field: a sorted set of allowed values plus the explicit
/// `*` flag used by the day-of-month/day-of-week rule.
final class _CronField {
  _CronField({
    required this.label,
    required Set<int> values,
    required this.isWildcard,
  }) : sorted = List<int>.unmodifiable(values.toList()..sort());

  static _CronField parse({
    required String label,
    required String raw,
    required int min,
    required int max,
    Map<String, int> aliases = const <String, int>{},
    int Function(int value)? normalize,
  }) {
    if (raw.isEmpty) {
      throwAutomation(
        AutomationErrorKind.invalidSchedule,
        'Поле «$label» пустое.',
      );
    }
    if (raw == '*') {
      final values = <int>{
        for (var value = min; value <= max; value += 1) value,
      };
      return _CronField(
        label: label,
        values: _normalizeAll(values, normalize),
        isWildcard: true,
      );
    }
    final values = <int>{};
    for (final term in raw.split(',')) {
      values.addAll(
        _parseTerm(
          label: label,
          term: term,
          min: min,
          max: max,
          aliases: aliases,
        ),
      );
    }
    if (values.isEmpty) {
      throwAutomation(
        AutomationErrorKind.invalidSchedule,
        'Поле «$label» не содержит значений.',
      );
    }
    return _CronField(
      label: label,
      values: _normalizeAll(values, normalize),
      isWildcard: false,
    );
  }

  static Set<int> _parseTerm({
    required String label,
    required String term,
    required int min,
    required int max,
    required Map<String, int> aliases,
  }) {
    if (term.isEmpty) {
      throwAutomation(
        AutomationErrorKind.invalidSchedule,
        'Поле «$label» содержит пустой элемент списка.',
      );
    }
    final withStep = term.split('/');
    if (withStep.length > 2) {
      throwAutomation(
        AutomationErrorKind.invalidSchedule,
        'В поле «$label» слишком много шагов в "$term".',
      );
    }
    final base = withStep[0];
    final step = withStep.length == 2
        ? _parseNumber(
            label: label,
            raw: withStep[1],
            min: 1,
            max: max - min + 1,
          )
        : 1;
    late final int start;
    late final int end;
    if (base == '*') {
      start = min;
      end = max;
    } else if (base.contains('-')) {
      final bounds = base.split('-');
      if (bounds.length != 2) {
        throwAutomation(
          AutomationErrorKind.invalidSchedule,
          'Диапазон "$base" в поле «$label» задан неверно.',
        );
      }
      start = _parseNumber(
        label: label,
        raw: bounds[0],
        min: min,
        max: max,
        aliases: aliases,
      );
      end = _parseNumber(
        label: label,
        raw: bounds[1],
        min: min,
        max: max,
        aliases: aliases,
      );
      if (start > end) {
        throwAutomation(
          AutomationErrorKind.invalidSchedule,
          'Диапазон "$base" в поле «$label» перевёрнут: начало больше конца.',
        );
      }
    } else {
      start = _parseNumber(
        label: label,
        raw: base,
        min: min,
        max: max,
        aliases: aliases,
      );
      // A bare "start/step" (extension) runs from start to the field maximum.
      end = withStep.length == 2 ? max : start;
    }
    return <int>{for (var value = start; value <= end; value += step) value};
  }

  static int _parseNumber({
    required String label,
    required String raw,
    required int min,
    required int max,
    Map<String, int> aliases = const <String, int>{},
  }) {
    final candidate = raw.trim();
    final alias = aliases[candidate.toUpperCase()];
    if (alias != null) {
      return alias;
    }
    if (!RegExp(r'^\d+$').hasMatch(candidate)) {
      throwAutomation(
        AutomationErrorKind.invalidSchedule,
        'Значение "$candidate" в поле «$label» не число'
        '${aliases.isEmpty ? '' : ' и не поддерживаемое имя'}.',
      );
    }
    final value = int.parse(candidate);
    if (value < min || value > max) {
      throwAutomation(
        AutomationErrorKind.invalidSchedule,
        'Значение $value в поле «$label» вне диапазона $min..$max.',
      );
    }
    return value;
  }

  static Set<int> _normalizeAll(
    Set<int> values,
    int Function(int value)? normalize,
  ) {
    if (normalize == null) {
      return values;
    }
    return <int>{for (final value in values) normalize(value)};
  }

  final String label;
  final List<int> sorted;
  final bool isWildcard;

  bool matches(int value) => sorted.contains(value);
}

const Map<String, int> _monthAliases = <String, int>{
  'JAN': 1,
  'FEB': 2,
  'MAR': 3,
  'APR': 4,
  'MAY': 5,
  'JUN': 6,
  'JUL': 7,
  'AUG': 8,
  'SEP': 9,
  'OCT': 10,
  'NOV': 11,
  'DEC': 12,
};

const Map<String, int> _weekdayAliases = <String, int>{
  'SUN': 0,
  'MON': 1,
  'TUE': 2,
  'WED': 3,
  'THU': 4,
  'FRI': 5,
  'SAT': 6,
};
