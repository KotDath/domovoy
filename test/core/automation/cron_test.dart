import 'package:domovoy/core/automation/automation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/automation_fakes.dart';

void main() {
  final zones = automationTestZones();

  group('parsing', () {
    test('accepts the standard five fields with stars', () {
      final cron = CronExpression.parse('*/5 * * * *');
      expect(cron.expression, '*/5 * * * *');
      expect(cron.matchesWallClock(WallClockTime(2026, 1, 1, 0, 0)), isTrue);
      expect(cron.matchesWallClock(WallClockTime(2026, 1, 1, 0, 5)), isTrue);
      expect(cron.matchesWallClock(WallClockTime(2026, 1, 1, 0, 7)), isFalse);
    });

    test('accepts lists, ranges and steps', () {
      final cron = CronExpression.parse('1,5,10-20/5 9-18 * * 1-5');
      expect(cron.matchesWallClock(WallClockTime(2026, 1, 5, 9, 1)), isTrue);
      expect(cron.matchesWallClock(WallClockTime(2026, 1, 5, 9, 5)), isTrue);
      expect(cron.matchesWallClock(WallClockTime(2026, 1, 5, 9, 15)), isTrue);
      expect(cron.matchesWallClock(WallClockTime(2026, 1, 5, 9, 20)), isTrue);
      expect(cron.matchesWallClock(WallClockTime(2026, 1, 5, 9, 7)), isFalse);
      expect(cron.matchesWallClock(WallClockTime(2026, 1, 5, 8, 5)), isFalse);
      // 2026-01-05 is a Monday; Saturday must not match.
      expect(cron.matchesWallClock(WallClockTime(2026, 1, 10, 9, 5)), isFalse);
    });

    test('accepts the start/step extension', () {
      final cron = CronExpression.parse('5/15 * * * *');
      expect(cron.matchesWallClock(WallClockTime(2026, 1, 1, 0, 5)), isTrue);
      expect(cron.matchesWallClock(WallClockTime(2026, 1, 1, 0, 20)), isTrue);
      expect(cron.matchesWallClock(WallClockTime(2026, 1, 1, 0, 35)), isTrue);
      expect(cron.matchesWallClock(WallClockTime(2026, 1, 1, 0, 50)), isTrue);
      expect(cron.matchesWallClock(WallClockTime(2026, 1, 1, 0, 55)), isFalse);
    });

    test('accepts month and weekday names and both Sunday numbers', () {
      final byName = CronExpression.parse('0 0 * JAN MON');
      expect(byName.matchesDate(DateTime.utc(2026, 1, 5)), isTrue);
      expect(byName.matchesDate(DateTime.utc(2026, 2, 2)), isFalse);
      final byZero = CronExpression.parse('0 0 * * 0');
      final bySeven = CronExpression.parse('0 0 * * 7');
      expect(byZero.matchesDate(DateTime.utc(2026, 1, 4)), isTrue);
      expect(bySeven.matchesDate(DateTime.utc(2026, 1, 4)), isTrue);
    });

    test('rejects seconds, macros and ambiguous extensions', () {
      for (final expression in <String>[
        '* * * *',
        '0 */5 * * * *',
        '@daily',
        '0 0 ? * *',
        '0 0 L * *',
        '0 0 15W * *',
        '0 0 * * 5#2',
        '0 0 1 * * *',
      ]) {
        expect(
          () => CronExpression.parse(expression),
          throwsA(isA<AutomationException>()),
          reason: expression,
        );
      }
    });

    test('rejects out-of-range and malformed values with the field name', () {
      expect(
        () => CronExpression.parse('60 * * * *'),
        throwsA(
          isA<AutomationException>().having(
            (error) => error.error.message,
            'message',
            contains('Минуты'),
          ),
        ),
      );
      expect(
        () => CronExpression.parse('0 24 * * *'),
        throwsA(isA<AutomationException>()),
      );
      expect(
        () => CronExpression.parse('0 0 0 * *'),
        throwsA(
          isA<AutomationException>().having(
            (error) => error.error.message,
            'message',
            contains('День месяца'),
          ),
        ),
      );
      expect(
        () => CronExpression.parse('0 0 32 * *'),
        throwsA(isA<AutomationException>()),
      );
      expect(
        () => CronExpression.parse('0 0 * 13 *'),
        throwsA(isA<AutomationException>()),
      );
      expect(
        () => CronExpression.parse('0 0 * * 8'),
        throwsA(isA<AutomationException>()),
      );
      expect(
        () => CronExpression.parse('5-1 * * * *'),
        throwsA(
          isA<AutomationException>().having(
            (error) => error.error.message,
            'message',
            contains('перевёрнут'),
          ),
        ),
      );
      expect(
        () => CronExpression.parse('*/0 * * * *'),
        throwsA(isA<AutomationException>()),
      );
      expect(
        () => CronExpression.parse('1,,2 * * * *'),
        throwsA(isA<AutomationException>()),
      );
      expect(
        () => CronExpression.parse('*/x * * * *'),
        throwsA(isA<AutomationException>()),
      );
      expect(
        () => CronExpression.parse(''),
        throwsA(isA<AutomationException>()),
      );
    });

    test('normalizes whitespace and reports validity', () {
      expect(
        CronExpression.parse('  */5   * * * * ').expression,
        '*/5 * * * *',
      );
      expect(CronExpression.isValid('*/5 * * * *'), isTrue);
      expect(CronExpression.isValid('nope'), isFalse);
    });
  });

  group('day-of-month and day-of-week interaction', () {
    test('both restricted means OR (conventional cron)', () {
      final cron = CronExpression.parse('0 0 13 * 5');
      expect(cron.usesEitherDayField, isTrue);
      // 2026-02-13 is a Friday: both match.
      expect(cron.matchesDate(DateTime.utc(2026, 2, 13)), isTrue);
      // 2026-03-13 is a Friday too; use a month where they differ.
      // 2026-04-13 is a Monday: only day-of-month matches.
      expect(cron.matchesDate(DateTime.utc(2026, 4, 13)), isTrue);
      // 2026-04-17 is a Friday: only day-of-week matches.
      expect(cron.matchesDate(DateTime.utc(2026, 4, 17)), isTrue);
      // 2026-04-16 is a Thursday, not the 13th.
      expect(cron.matchesDate(DateTime.utc(2026, 4, 16)), isFalse);
    });

    test('one restricted field wins alone', () {
      final domOnly = CronExpression.parse('0 0 13 * *');
      expect(domOnly.usesEitherDayField, isFalse);
      expect(domOnly.matchesDate(DateTime.utc(2026, 4, 13)), isTrue);
      expect(domOnly.matchesDate(DateTime.utc(2026, 4, 17)), isFalse);
      final dowOnly = CronExpression.parse('0 0 * * 5');
      expect(dowOnly.matchesDate(DateTime.utc(2026, 4, 17)), isTrue);
      expect(dowOnly.matchesDate(DateTime.utc(2026, 4, 13)), isFalse);
    });

    test('*/n day fields are restricted, plain * is not', () {
      expect(CronExpression.parse('0 0 */2 * *').restrictsDayOfMonth, isTrue);
      expect(CronExpression.parse('0 0 * * *').restrictsDayOfMonth, isFalse);
      expect(CronExpression.parse('0 0 * * */2').restrictsDayOfWeek, isTrue);
    });
  });

  group('next occurrences', () {
    test('*/5 finds the next step strictly after the cursor', () {
      final cron = CronExpression.parse('*/5 * * * *');
      final next = cron.nextAfter(
        afterUtc: DateTime.utc(2026, 1, 1, 10, 2),
        timeZoneId: 'UTC',
        zones: zones,
      );
      expect(next, DateTime.utc(2026, 1, 1, 10, 5));
      final exactly = cron.nextAfter(
        afterUtc: DateTime.utc(2026, 1, 1, 10, 5),
        timeZoneId: 'UTC',
        zones: zones,
      );
      expect(exactly, DateTime.utc(2026, 1, 1, 10, 10));
    });

    test('crosses month and year boundaries', () {
      final firstOfMonth = CronExpression.parse('0 0 1 * *');
      expect(
        firstOfMonth.nextAfter(
          afterUtc: DateTime.utc(2026, 1, 31, 23, 59),
          timeZoneId: 'UTC',
          zones: zones,
        ),
        DateTime.utc(2026, 2, 1),
      );
      expect(
        firstOfMonth.nextAfter(
          afterUtc: DateTime.utc(2026, 12, 31, 23, 59),
          timeZoneId: 'UTC',
          zones: zones,
        ),
        DateTime.utc(2027, 1, 1),
      );
    });

    test('31st skips months without that day', () {
      final endOfMonth = CronExpression.parse('0 0 31 * *');
      expect(
        endOfMonth.nextAfter(
          afterUtc: DateTime.utc(2026, 2, 1),
          timeZoneId: 'UTC',
          zones: zones,
        ),
        DateTime.utc(2026, 3, 31),
      );
    });

    test('leap day recurs every four years and returns three occurrences', () {
      final leap = CronExpression.parse('0 0 29 2 *');
      final occurrences = leap.nextOccurrences(
        afterUtc: DateTime.utc(2026, 3, 1),
        timeZoneId: 'UTC',
        zones: zones,
        count: 3,
      );
      expect(occurrences, <DateTime>[
        DateTime.utc(2028, 2, 29),
        DateTime.utc(2032, 2, 29),
        DateTime.utc(2036, 2, 29),
      ]);
    });

    test('impossible dates are rejected as unreachable instead of looping', () {
      final impossible = CronExpression.parse('0 0 30 2 *');
      final stopwatch = Stopwatch()..start();
      expect(
        impossible.nextAfter(
          afterUtc: DateTime.utc(2026, 1, 1),
          timeZoneId: 'UTC',
          zones: zones,
        ),
        isNull,
      );
      expect(
        impossible.lastAtOrBefore(
          boundUtc: DateTime.utc(2036, 1, 1),
          timeZoneId: 'UTC',
          zones: zones,
        ),
        isNull,
      );
      stopwatch.stop();
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(
        () => impossible.validateReachable(timeZoneId: 'UTC', zones: zones),
        throwsA(
          isA<AutomationException>().having(
            (error) => error.error.kind,
            'kind',
            AutomationErrorKind.invalidSchedule,
          ),
        ),
      );
    });

    test('31 April and 31 June are unreachable', () {
      for (final expression in <String>['0 0 31 4 *', '0 0 31 6 *']) {
        final cron = CronExpression.parse(expression);
        expect(
          cron.nextAfter(
            afterUtc: DateTime.utc(2026, 1, 1),
            timeZoneId: 'UTC',
            zones: zones,
          ),
          isNull,
          reason: expression,
        );
      }
    });

    test('lastAtOrBefore returns the freshest occurrence at or before now', () {
      final cron = CronExpression.parse('*/5 * * * *');
      expect(
        cron.lastAtOrBefore(
          boundUtc: DateTime.utc(2026, 1, 1, 10, 7),
          timeZoneId: 'UTC',
          zones: zones,
        ),
        DateTime.utc(2026, 1, 1, 10, 5),
      );
      expect(
        cron.lastAtOrBefore(
          boundUtc: DateTime.utc(2026, 1, 1, 10, 5),
          timeZoneId: 'UTC',
          zones: zones,
        ),
        DateTime.utc(2026, 1, 1, 10, 5),
      );
    });

    test('respects the explicit IANA zone offset', () {
      final cron = CronExpression.parse('0 9 * * *');
      final next = cron.nextAfter(
        afterUtc: DateTime.utc(2026, 1, 1, 0),
        timeZoneId: 'Europe/Moscow',
        zones: zones,
      );
      expect(next, DateTime.utc(2026, 1, 1, 6));
    });
  });
}
