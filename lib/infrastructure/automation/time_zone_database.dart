import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../../core/automation/automation.dart';

var _timeZonesInitialized = false;

/// Loads the embedded IANA database once per process.
///
/// The embedded `data/latest_all.dart` initializer is a pure Dart library, so
/// it works on every platform Domovoy targets, including web, and needs no
/// asset fetch at runtime. The package's `standalone.dart` initializer is
/// explicitly unsuitable for Flutter (it reads `.tzf` files through `dart:io`),
/// and the browser initializer would require serving the database as a web
/// asset; neither is used here. The local device zone is never read: every
/// schedule stores an explicit IANA id and resolves it through this adapter.
void ensureAutomationTimeZonesInitialized() {
  if (_timeZonesInitialized) {
    return;
  }
  tz_data.initializeTimeZones();
  _timeZonesInitialized = true;
}

/// Common spellings that the compiled database stores under `Etc/...`.
const _zoneAliases = <String, String>{
  'UTC': 'Etc/UTC',
  'GMT': 'Etc/GMT',
  'Zulu': 'Etc/UTC',
};

/// `timezone`-backed implementation of the scheduler's zone contract.
///
/// DST semantics are explicit:
/// - a spring-forward gap returns **no** instants, so the cron search skips the
///   nonexistent wall-clock reading for that day;
/// - an autumn fold returns **two** instants (sorted), and the scheduler fires
///   once at the earlier one.
final class PackageAutomationTimeZones implements AutomationTimeZones {
  PackageAutomationTimeZones({bool initialize = true}) {
    if (initialize) {
      ensureAutomationTimeZonesInitialized();
    }
  }

  @override
  bool isKnownZone(String zoneId) {
    final candidate = _canonicalZoneId(zoneId);
    return tz.timeZoneDatabase.locations.containsKey(candidate);
  }

  @override
  WallClockTime localTime(String zoneId, DateTime utc) {
    final location = _location(zoneId);
    final local = tz.TZDateTime.from(utc.toUtc(), location);
    return WallClockTime(
      local.year,
      local.month,
      local.day,
      local.hour,
      local.minute,
    );
  }

  @override
  List<DateTime> resolveLocal(String zoneId, WallClockTime local) {
    final location = _location(zoneId);
    final approximate = local.asDateTimeFields;
    final offsets = <int>{};
    for (final shift in const <Duration>[
      Duration(days: -1),
      Duration.zero,
      Duration(days: 1),
    ]) {
      offsets.add(
        location
            .timeZone(approximate.add(shift).millisecondsSinceEpoch)
            .offset
            .inMilliseconds,
      );
    }
    final instants = <DateTime>[];
    for (final offset in offsets) {
      final candidate = approximate.subtract(Duration(milliseconds: offset));
      final back = tz.TZDateTime.from(candidate, location);
      if (back.year == local.year &&
          back.month == local.month &&
          back.day == local.day &&
          back.hour == local.hour &&
          back.minute == local.minute) {
        final utc = candidate.toUtc();
        if (!instants.any((existing) => existing.isAtSameMomentAs(utc))) {
          instants.add(utc);
        }
      }
    }
    instants.sort();
    return List<DateTime>.unmodifiable(instants);
  }

  tz.Location _location(String zoneId) {
    final candidate = _canonicalZoneId(zoneId);
    try {
      return tz.getLocation(candidate);
    } on Object {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'Неизвестный часовой пояс "$candidate".',
      );
    }
  }

  String _canonicalZoneId(String zoneId) {
    final trimmed = zoneId.trim();
    return _zoneAliases[trimmed] ?? trimmed;
  }
}
