import 'package:domovoy/core/automation/automation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/automation_fakes.dart';

void main() {
  final zones = automationTestZones();

  group('one-shot schedule', () {
    test('round-trips through JSON', () {
      final schedule = AutomationSchedule.oneShot(DateTime.utc(2026, 5, 1, 12));
      final decoded = AutomationSchedule.fromJson(schedule.toJson());
      expect(decoded, isA<OneShotSchedule>());
      expect((decoded as OneShotSchedule).atUtc, DateTime.utc(2026, 5, 1, 12));
      expect(decoded.kind, 'oneShot');
      expect(decoded.timeZoneId, isNull);
    });

    test('nextAfter is strictly after the stored instant', () {
      final schedule = AutomationSchedule.oneShot(DateTime.utc(2026, 5, 1, 12));
      expect(
        schedule.nextAfter(DateTime.utc(2026, 5, 1, 11), zones),
        DateTime.utc(2026, 5, 1, 12),
      );
      expect(schedule.nextAfter(DateTime.utc(2026, 5, 1, 12), zones), isNull);
      expect(
        schedule.lastAtOrBefore(DateTime.utc(2026, 5, 1, 12), zones),
        DateTime.utc(2026, 5, 1, 12),
      );
      expect(
        schedule.lastAtOrBefore(DateTime.utc(2026, 5, 1, 11), zones),
        isNull,
      );
    });

    test('preview returns a single future instant', () {
      final schedule = AutomationSchedule.oneShot(DateTime.utc(2026, 5, 1, 12));
      expect(
        schedule.nextOccurrences(
          afterUtc: DateTime.utc(2026, 5, 1, 11),
          zones: zones,
        ),
        <DateTime>[DateTime.utc(2026, 5, 1, 12)],
      );
      expect(
        schedule.nextOccurrences(
          afterUtc: DateTime.utc(2026, 5, 1, 13),
          zones: zones,
        ),
        isEmpty,
      );
    });
  });

  group('cron schedule', () {
    test('round-trips and keeps the explicit IANA zone', () {
      final schedule = AutomationSchedule.cron(
        expression: '*/5 * * * *',
        timeZoneId: 'Europe/Moscow',
      );
      final decoded = AutomationSchedule.fromJson(schedule.toJson());
      expect(decoded, isA<CronSchedule>());
      final cron = decoded as CronSchedule;
      expect(cron.expression, '*/5 * * * *');
      expect(cron.timeZoneId, 'Europe/Moscow');
      expect(cron.summary, '*/5 * * * * (Europe/Moscow)');
    });

    test('validate rejects an unknown zone', () {
      final schedule = AutomationSchedule.cron(
        expression: '*/5 * * * *',
        timeZoneId: 'Mars/Olympus',
      );
      expect(
        () => schedule.validate(zones),
        throwsA(
          isA<AutomationException>().having(
            (error) => error.error.kind,
            'kind',
            AutomationErrorKind.invalidSchedule,
          ),
        ),
      );
    });

    test('validate rejects an unreachable expression', () {
      final schedule = AutomationSchedule.cron(
        expression: '0 0 30 2 *',
        timeZoneId: 'UTC',
      );
      expect(
        () => schedule.validate(zones),
        throwsA(isA<AutomationException>()),
      );
    });

    test('validate accepts a reachable expression', () {
      final schedule = AutomationSchedule.cron(
        expression: '0 0 29 2 *',
        timeZoneId: 'UTC',
      );
      expect(() => schedule.validate(zones), returnsNormally);
    });

    test('preview returns three occurrences in the stored zone', () {
      final schedule = AutomationSchedule.cron(
        expression: '0 9 * * *',
        timeZoneId: 'Europe/Moscow',
      );
      final preview = schedule.nextOccurrences(
        afterUtc: DateTime.utc(2026, 1, 1, 0),
        zones: zones,
        count: 3,
      );
      expect(preview, <DateTime>[
        DateTime.utc(2026, 1, 1, 6),
        DateTime.utc(2026, 1, 2, 6),
        DateTime.utc(2026, 1, 3, 6),
      ]);
    });
  });

  group('schedule JSON errors', () {
    test('rejects an unknown kind and missing fields', () {
      expect(
        () => AutomationSchedule.fromJson(<String, Object?>{'kind': 'every'}),
        throwsA(isA<AutomationException>()),
      );
      expect(
        () => AutomationSchedule.fromJson(<String, Object?>{'kind': 'cron'}),
        throwsA(isA<AutomationException>()),
      );
      expect(
        () => AutomationSchedule.fromJson(<String, Object?>{
          'kind': 'oneShot',
          'at': 'not-a-date',
        }),
        throwsA(isA<AutomationException>()),
      );
    });

    test('rejects an invalid cron expression at construction', () {
      expect(
        () => AutomationSchedule.cron(expression: 'nope', timeZoneId: 'UTC'),
        throwsA(
          isA<AutomationException>().having(
            (error) => error.error.kind,
            'kind',
            AutomationErrorKind.invalidSchedule,
          ),
        ),
      );
    });
  });
}
