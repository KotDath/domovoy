import 'package:domovoy/core/automation/automation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/automation_fakes.dart';

/// The fake zone models New York: UTC-5 standard, UTC-4 after the spring
/// transition at 2026-03-08T07:00Z, back to UTC-5 after 2026-11-01T06:00Z.
void main() {
  final zones = automationTestZones();

  group('spring-forward gap', () {
    test('a nonexistent wall time is skipped for that day', () {
      final cron = CronExpression.parse('0 2 * * *');
      final next = cron.nextAfter(
        afterUtc: DateTime.utc(2026, 3, 8, 0),
        timeZoneId: 'America/New_York',
        zones: zones,
      );
      // 02:00 does not exist on 2026-03-08; the next 02:00 is on 03-09 EDT.
      expect(next, DateTime.utc(2026, 3, 9, 6));
    });

    test('every reading inside the gap is skipped', () {
      final cron = CronExpression.parse('*/30 * * * *');
      final next = cron.nextAfter(
        afterUtc: DateTime.utc(2026, 3, 8, 6, 45),
        timeZoneId: 'America/New_York',
        zones: zones,
      );
      // 01:45 EST + 15 min = 02:00 and 02:30 do not exist; 03:00 EDT = 07:00Z.
      expect(next, DateTime.utc(2026, 3, 8, 7));
    });

    test('resolveLocal returns no instants for the gap', () {
      expect(
        zones.resolveLocal(
          'America/New_York',
          WallClockTime(2026, 3, 8, 2, 30),
        ),
        isEmpty,
      );
      expect(
        zones.resolveLocal(
          'America/New_York',
          WallClockTime(2026, 3, 8, 1, 30),
        ),
        <DateTime>[DateTime.utc(2026, 3, 8, 6, 30)],
      );
      expect(
        zones.resolveLocal(
          'America/New_York',
          WallClockTime(2026, 3, 8, 3, 30),
        ),
        <DateTime>[DateTime.utc(2026, 3, 8, 7, 30)],
      );
    });
  });

  group('autumn fold', () {
    test('resolveLocal returns both instants sorted', () {
      // US clocks fall back from 02:00 EDT to 01:00 EST at 06:00Z, so the
      // repeated wall-clock hour is 01:00–01:59: 05:30Z (EDT) then 06:30Z.
      expect(
        zones.resolveLocal(
          'America/New_York',
          WallClockTime(2026, 11, 1, 1, 30),
        ),
        <DateTime>[
          DateTime.utc(2026, 11, 1, 5, 30),
          DateTime.utc(2026, 11, 1, 6, 30),
        ],
      );
      expect(
        zones.resolveLocal(
          'America/New_York',
          WallClockTime(2026, 11, 1, 2, 30),
        ),
        <DateTime>[DateTime.utc(2026, 11, 1, 7, 30)],
      );
    });

    test('a repeated wall time fires once at the earlier instant', () {
      final cron = CronExpression.parse('30 1 * * *');
      final first = cron.nextAfter(
        afterUtc: DateTime.utc(2026, 11, 1, 4),
        timeZoneId: 'America/New_York',
        zones: zones,
      );
      expect(first, DateTime.utc(2026, 11, 1, 5, 30));
      final second = cron.nextAfter(
        afterUtc: first!,
        timeZoneId: 'America/New_York',
        zones: zones,
      );
      // The repeated 01:30 EST at 06:30Z is not a second fire.
      expect(second, DateTime.utc(2026, 11, 2, 6, 30));
    });

    test('per-minute expressions never fire twice for one wall time', () {
      final cron = CronExpression.parse('* * * * *');
      final afterFirst = cron.nextAfter(
        afterUtc: DateTime.utc(2026, 11, 1, 5, 30),
        timeZoneId: 'America/New_York',
        zones: zones,
      );
      expect(afterFirst, DateTime.utc(2026, 11, 1, 5, 31));
      // Inside the second pass the already-used wall times are not repeated:
      // 01:31–01:59 EST already fired at their earlier instants, so the next
      // fire is 02:00 EST.
      final afterSecondPassStart = cron.nextAfter(
        afterUtc: DateTime.utc(2026, 11, 1, 6, 30),
        timeZoneId: 'America/New_York',
        zones: zones,
      );
      expect(afterSecondPassStart, DateTime.utc(2026, 11, 1, 7));
    });

    test('lastAtOrBefore returns the earlier-pass instant', () {
      final cron = CronExpression.parse('* * * * *');
      // 06:59Z is 01:59 EST; the occurrence of wall 01:59 was at 05:59Z.
      expect(
        cron.lastAtOrBefore(
          boundUtc: DateTime.utc(2026, 11, 1, 6, 59),
          timeZoneId: 'America/New_York',
          zones: zones,
        ),
        DateTime.utc(2026, 11, 1, 5, 59),
      );
      // 07:29Z is 02:29 EST, an ordinary reading after the fold.
      expect(
        cron.lastAtOrBefore(
          boundUtc: DateTime.utc(2026, 11, 1, 7, 29),
          timeZoneId: 'America/New_York',
          zones: zones,
        ),
        DateTime.utc(2026, 11, 1, 7, 29),
      );
    });
  });

  group('zones without DST', () {
    test('Moscow 02:00 is 23:00Z the previous day', () {
      final cron = CronExpression.parse('0 2 * * *');
      expect(
        cron.nextAfter(
          afterUtc: DateTime.utc(2026, 3, 8, 0),
          timeZoneId: 'Europe/Moscow',
          zones: zones,
        ),
        DateTime.utc(2026, 3, 8, 23),
      );
    });

    test('UTC is stable across the DST dates', () {
      final cron = CronExpression.parse('0 2 * * *');
      expect(
        cron.nextAfter(
          afterUtc: DateTime.utc(2026, 3, 8, 0),
          timeZoneId: 'UTC',
          zones: zones,
        ),
        DateTime.utc(2026, 3, 8, 2),
      );
      expect(
        cron.nextAfter(
          afterUtc: DateTime.utc(2026, 11, 1, 0),
          timeZoneId: 'UTC',
          zones: zones,
        ),
        DateTime.utc(2026, 11, 1, 2),
      );
    });

    test('an unknown zone is rejected visibly', () {
      expect(
        () => zones.localTime('Mars/Olympus', DateTime.utc(2026)),
        throwsA(isA<AutomationException>()),
      );
    });
  });
}
