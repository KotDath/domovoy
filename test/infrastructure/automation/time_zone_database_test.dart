import 'package:domovoy/core/automation/automation.dart';
import 'package:domovoy/infrastructure/automation/time_zone_database.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final zones = PackageAutomationTimeZones();

  test('initialization is idempotent', () {
    ensureAutomationTimeZonesInitialized();
    ensureAutomationTimeZonesInitialized();
    expect(zones.isKnownZone('UTC'), isTrue);
  });

  group('zone lookup', () {
    test('recognizes IANA ids and rejects everything else', () {
      expect(zones.isKnownZone('UTC'), isTrue);
      expect(zones.isKnownZone('Europe/Moscow'), isTrue);
      expect(zones.isKnownZone('America/New_York'), isTrue);
      expect(zones.isKnownZone('Australia/Sydney'), isTrue);
      expect(zones.isKnownZone('Mars/Olympus'), isFalse);
      expect(zones.isKnownZone('europe/moscow'), isFalse);
      expect(zones.isKnownZone(''), isFalse);
    });

    test('localTime converts UTC through the zone offset', () {
      expect(
        zones.localTime('Europe/Moscow', DateTime.utc(2026, 1, 1, 12)),
        WallClockTime(2026, 1, 1, 15, 0),
      );
      expect(
        zones.localTime('America/New_York', DateTime.utc(2026, 1, 1, 12)),
        WallClockTime(2026, 1, 1, 7, 0),
      );
      expect(
        zones.localTime('Asia/Kathmandu', DateTime.utc(2026, 1, 1, 12)),
        WallClockTime(2026, 1, 1, 17, 45),
      );
    });

    test('an unknown zone fails visibly', () {
      expect(
        () => zones.localTime('Mars/Olympus', DateTime.utc(2026)),
        throwsA(isA<AutomationException>()),
      );
    });
  });

  group('America/New_York DST', () {
    test('spring gap returns no instants', () {
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

    test('autumn fold returns two sorted instants', () {
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
    });

    test('a 02:00 task skips the gap day', () {
      final cron = CronExpression.parse('0 2 * * *');
      expect(
        cron.nextAfter(
          afterUtc: DateTime.utc(2026, 3, 8, 0),
          timeZoneId: 'America/New_York',
          zones: zones,
        ),
        DateTime.utc(2026, 3, 9, 6),
      );
    });

    test('*/5 crosses the gap without firing at a nonexistent time', () {
      final cron = CronExpression.parse('*/5 * * * *');
      expect(
        cron.nextAfter(
          afterUtc: DateTime.utc(2026, 3, 8, 6, 55),
          timeZoneId: 'America/New_York',
          zones: zones,
        ),
        DateTime.utc(2026, 3, 8, 7),
      );
    });

    test('a 01:30 task fires once at the earlier fold instant', () {
      final cron = CronExpression.parse('30 1 * * *');
      final first = cron.nextAfter(
        afterUtc: DateTime.utc(2026, 11, 1, 4),
        timeZoneId: 'America/New_York',
        zones: zones,
      );
      expect(first, DateTime.utc(2026, 11, 1, 5, 30));
      expect(
        cron.nextAfter(
          afterUtc: first!,
          timeZoneId: 'America/New_York',
          zones: zones,
        ),
        DateTime.utc(2026, 11, 2, 6, 30),
      );
    });
  });

  group('Europe/Berlin DST', () {
    test('spring gap skips the nonexistent 02:30', () {
      final cron = CronExpression.parse('30 2 * * *');
      expect(
        cron.nextAfter(
          afterUtc: DateTime.utc(2026, 3, 28, 12),
          timeZoneId: 'Europe/Berlin',
          zones: zones,
        ),
        DateTime.utc(2026, 3, 30, 0, 30),
      );
    });

    test('autumn fold fires at the earlier instant only', () {
      final cron = CronExpression.parse('30 2 * * *');
      final first = cron.nextAfter(
        afterUtc: DateTime.utc(2026, 10, 25, 0),
        timeZoneId: 'Europe/Berlin',
        zones: zones,
      );
      expect(first, DateTime.utc(2026, 10, 25, 0, 30));
      expect(
        cron.nextAfter(
          afterUtc: first!,
          timeZoneId: 'Europe/Berlin',
          zones: zones,
        ),
        DateTime.utc(2026, 10, 26, 1, 30),
      );
    });
  });

  group('Australia/Sydney (southern hemisphere)', () {
    test('spring gap skips the nonexistent 02:30', () {
      final cron = CronExpression.parse('30 2 * * *');
      expect(
        cron.nextAfter(
          afterUtc: DateTime.utc(2026, 10, 3, 12),
          timeZoneId: 'Australia/Sydney',
          zones: zones,
        ),
        DateTime.utc(2026, 10, 4, 15, 30),
      );
    });

    test('autumn fold fires once', () {
      final cron = CronExpression.parse('30 2 * * *');
      final first = cron.nextAfter(
        afterUtc: DateTime.utc(2026, 4, 4, 12),
        timeZoneId: 'Australia/Sydney',
        zones: zones,
      );
      expect(first, DateTime.utc(2026, 4, 4, 15, 30));
      expect(
        cron.nextAfter(
          afterUtc: first!,
          timeZoneId: 'Australia/Sydney',
          zones: zones,
        ),
        DateTime.utc(2026, 4, 5, 16, 30),
      );
    });
  });

  group('month boundaries and impossible dates', () {
    test('the first of the month respects the zone offset', () {
      final cron = CronExpression.parse('0 0 1 * *');
      expect(
        cron.nextAfter(
          afterUtc: DateTime.utc(2026, 1, 31, 20, 59),
          timeZoneId: 'Europe/Moscow',
          zones: zones,
        ),
        DateTime.utc(2026, 1, 31, 21),
      );
    });

    test('29 February is reachable and 30 February is not', () {
      final leap = CronExpression.parse('0 0 29 2 *');
      expect(
        leap.nextAfter(
          afterUtc: DateTime.utc(2026, 1, 1),
          timeZoneId: 'Europe/Moscow',
          zones: zones,
        ),
        DateTime.utc(2028, 2, 28, 21),
      );
      expect(
        () => CronExpression.parse(
          '0 0 30 2 *',
        ).validateReachable(timeZoneId: 'Europe/Moscow', zones: zones),
        throwsA(
          isA<AutomationException>().having(
            (error) => error.error.kind,
            'kind',
            AutomationErrorKind.invalidSchedule,
          ),
        ),
      );
    });

    test('31 April never fires in any zone', () {
      expect(
        CronExpression.parse('0 0 31 4 *').nextAfter(
          afterUtc: DateTime.utc(2026, 1, 1),
          timeZoneId: 'America/New_York',
          zones: zones,
        ),
        isNull,
      );
    });

    test('a schedule round-trips and previews three real instants', () {
      final schedule = AutomationSchedule.cron(
        expression: '0 9 * * 1-5',
        timeZoneId: 'Europe/Berlin',
      );
      final decoded = AutomationSchedule.fromJson(schedule.toJson());
      decoded.validate(zones);
      final preview = decoded.nextOccurrences(
        afterUtc: DateTime.utc(2026, 3, 27, 12),
        zones: zones,
        count: 3,
      );
      expect(preview, <DateTime>[
        DateTime.utc(2026, 3, 30, 7),
        DateTime.utc(2026, 3, 31, 7),
        DateTime.utc(2026, 4, 1, 7),
      ]);
    });
  });
}
