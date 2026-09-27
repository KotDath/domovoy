import 'errors.dart';
import 'wall_clock.dart';

/// IANA time zone boundary used by the scheduler.
///
/// The contract is deliberately narrow: a schedule stores an explicit IANA zone
/// id and every conversion goes through this interface. `core` never imports a
/// timezone package, so the DST policy below stays in one place and the
/// platform adapter (B6 infrastructure) is the only code that loads a database.
abstract interface class AutomationTimeZones {
  /// Whether [zoneId] is a known IANA zone name.
  bool isKnownZone(String zoneId);

  /// UTC instants of one local wall-clock reading in [zoneId].
  ///
  /// The list is sorted and holds:
  /// - two instants when the reading repeats (autumn DST fold),
  /// - one instant for an ordinary reading,
  /// - no instants when the reading does not exist (spring DST gap).
  ///
  /// Throws [AutomationException] with [AutomationErrorKind.invalidInput] for
  /// an unknown zone.
  List<DateTime> resolveLocal(String zoneId, WallClockTime local);

  /// Local wall-clock reading of the UTC instant [utc] in [zoneId].
  WallClockTime localTime(String zoneId, DateTime utc);
}

/// Rejects an unknown or non-IANA time zone id.
String normalizeTimeZoneId(String raw, AutomationTimeZones zones) {
  final candidate = raw.trim();
  if (candidate.isEmpty || candidate.length > 64) {
    throwAutomation(
      AutomationErrorKind.invalidSchedule,
      'Часовой пояс должен быть непустым IANA-именем, например Europe/Moscow.',
    );
  }
  if (candidate.contains(RegExp(r'[^A-Za-z0-9_+\-/]'))) {
    throwAutomation(
      AutomationErrorKind.invalidSchedule,
      'Часовой пояс "$candidate" содержит недопустимые символы.',
    );
  }
  if (!zones.isKnownZone(candidate)) {
    throwAutomation(
      AutomationErrorKind.invalidSchedule,
      'Неизвестный часовой пояс "$candidate". Укажите IANA-имя, например '
      'Europe/Moscow или America/New_York.',
    );
  }
  return candidate;
}
