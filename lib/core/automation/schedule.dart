import 'cron.dart';
import 'errors.dart';
import 'json.dart';
import 'time_zones.dart';

/// When one automation task fires.
///
/// A schedule is either a single UTC instant or a conventional five-field cron
/// expression bound to an explicit IANA time zone. All computed instants are
/// UTC; the time zone is used only to read wall-clock fields, which keeps
/// `scheduledAt` idempotency independent of DST transitions.
sealed class AutomationSchedule {
  const AutomationSchedule();

  factory AutomationSchedule.fromJson(Object? json) {
    if (json is! Map) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'Расписание должно быть JSON-объектом.',
      );
    }
    final kind = json['kind'];
    switch (kind) {
      case 'oneShot':
        final raw = json['at'];
        if (raw is! String) {
          throwAutomation(
            AutomationErrorKind.invalidInput,
            'Разовая задача должна содержать момент "at".',
          );
        }
        final at = DateTime.tryParse(raw);
        if (at == null) {
          throwAutomation(
            AutomationErrorKind.invalidInput,
            'Момент разовой задачи не является ISO 8601: "$raw".',
          );
        }
        return OneShotSchedule(at);
      case 'cron':
        final expression = json['expression'];
        final timeZone = json['timeZone'];
        if (expression is! String || timeZone is! String) {
          throwAutomation(
            AutomationErrorKind.invalidInput,
            'Cron-расписание требует поля "expression" и "timeZone".',
          );
        }
        return CronSchedule(expression: expression, timeZoneId: timeZone);
      default:
        throwAutomation(
          AutomationErrorKind.invalidInput,
          'Неизвестный вид расписания "$kind".',
        );
    }
  }

  /// Single UTC instant.
  factory AutomationSchedule.oneShot(DateTime atUtc) => OneShotSchedule(atUtc);

  /// Five-field cron in an explicit IANA time zone.
  factory AutomationSchedule.cron({
    required String expression,
    required String timeZoneId,
  }) => CronSchedule(expression: expression, timeZoneId: timeZoneId);

  /// Stable discriminator used on the wire and in the JSONL envelope.
  String get kind;

  /// IANA zone id, or null for a one-shot instant.
  String? get timeZoneId;

  /// One human-readable line for `list_tasks` and the tasks UI.
  String get summary;

  Map<String, Object?> toJson();

  /// Validates the time zone and proves the expression can actually fire.
  void validate(AutomationTimeZones zones);

  /// Next occurrence strictly after [afterUtc], or null when none exists.
  DateTime? nextAfter(DateTime afterUtc, AutomationTimeZones zones);

  /// Up to [count] occurrences strictly after [afterUtc].
  List<DateTime> nextOccurrences({
    required DateTime afterUtc,
    required AutomationTimeZones zones,
    int count = 3,
  });

  /// Latest occurrence at or before [boundUtc], or null when there is none.
  DateTime? lastAtOrBefore(DateTime boundUtc, AutomationTimeZones zones);
}

/// A task that fires exactly once at a stored UTC instant.
final class OneShotSchedule extends AutomationSchedule {
  OneShotSchedule(DateTime atUtc) : atUtc = atUtc.toUtc();

  final DateTime atUtc;

  @override
  String get kind => 'oneShot';

  @override
  String? get timeZoneId => null;

  @override
  String get summary => 'Один раз: ${atUtc.toIso8601String()}';

  @override
  Map<String, Object?> toJson() => freezeJsonMap(<String, Object?>{
    'kind': kind,
    'at': atUtc.toIso8601String(),
  });

  @override
  void validate(AutomationTimeZones zones) {}

  @override
  DateTime? nextAfter(DateTime afterUtc, AutomationTimeZones zones) =>
      atUtc.isAfter(afterUtc) ? atUtc : null;

  @override
  List<DateTime> nextOccurrences({
    required DateTime afterUtc,
    required AutomationTimeZones zones,
    int count = 3,
  }) {
    if (count <= 0 || !atUtc.isAfter(afterUtc)) {
      return const <DateTime>[];
    }
    return List<DateTime>.unmodifiable(<DateTime>[atUtc]);
  }

  @override
  DateTime? lastAtOrBefore(DateTime boundUtc, AutomationTimeZones zones) =>
      atUtc.isAfter(boundUtc) ? null : atUtc;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is OneShotSchedule && other.atUtc == atUtc;

  @override
  int get hashCode => Object.hash(kind, atUtc);

  @override
  String toString() => 'OneShotSchedule(${atUtc.toIso8601String()})';
}

/// A recurring five-field cron expression in an explicit IANA time zone.
final class CronSchedule extends AutomationSchedule {
  CronSchedule({required String expression, required String timeZoneId})
    : cron = CronExpression.parse(expression),
      timeZoneId = timeZoneId.trim();

  final CronExpression cron;

  @override
  final String timeZoneId;

  @override
  String get kind => 'cron';

  String get expression => cron.expression;

  @override
  String get summary => '${cron.expression} ($timeZoneId)';

  @override
  Map<String, Object?> toJson() => freezeJsonMap(<String, Object?>{
    'kind': kind,
    'expression': cron.expression,
    'timeZone': timeZoneId,
  });

  @override
  void validate(AutomationTimeZones zones) {
    final zone = normalizeTimeZoneId(timeZoneId, zones);
    cron.validateReachable(timeZoneId: zone, zones: zones);
  }

  @override
  DateTime? nextAfter(DateTime afterUtc, AutomationTimeZones zones) =>
      cron.nextAfter(afterUtc: afterUtc, timeZoneId: timeZoneId, zones: zones);

  @override
  List<DateTime> nextOccurrences({
    required DateTime afterUtc,
    required AutomationTimeZones zones,
    int count = 3,
  }) => cron.nextOccurrences(
    afterUtc: afterUtc,
    timeZoneId: timeZoneId,
    zones: zones,
    count: count,
  );

  @override
  DateTime? lastAtOrBefore(DateTime boundUtc, AutomationTimeZones zones) => cron
      .lastAtOrBefore(boundUtc: boundUtc, timeZoneId: timeZoneId, zones: zones);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CronSchedule &&
          other.cron.expression == cron.expression &&
          other.timeZoneId == timeZoneId;

  @override
  int get hashCode => Object.hash(kind, cron.expression, timeZoneId);

  @override
  String toString() => 'CronSchedule($expression, $timeZoneId)';
}
