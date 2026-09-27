import 'errors.dart';
import 'json.dart';

/// One timezone-free local calendar reading with minute precision.
///
/// The cron search works on wall-clock values and only converts them to UTC
/// instants through [AutomationTimeZones]. Keeping the value type free of any
/// timezone package lets the DST policy live in `core` and stay testable with
/// a fake zone database.
final class WallClockTime implements Comparable<WallClockTime> {
  WallClockTime(this.year, this.month, this.day, this.hour, this.minute) {
    if (month < 1 || month > 12) {
      throwAutomation(
        AutomationErrorKind.invalidSchedule,
        'Месяц должен быть от 1 до 12, получено $month.',
      );
    }
    final lastDay = DateTime.utc(year, month + 1, 0).day;
    if (day < 1 || day > lastDay) {
      throwAutomation(
        AutomationErrorKind.invalidSchedule,
        'Дня $day нет в месяце $month года $year.',
      );
    }
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) {
      throwAutomation(
        AutomationErrorKind.invalidSchedule,
        'Некорректное время $hour:$minute.',
      );
    }
  }

  /// Calendar reading of [value], ignoring seconds and sub-minute precision.
  factory WallClockTime.fromDateTime(DateTime value) => WallClockTime(
    value.year,
    value.month,
    value.day,
    value.hour,
    value.minute,
  );

  factory WallClockTime.fromJson(Object? json) {
    if (json is! Map) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'Wall clock value must be an object.',
      );
    }
    final year = json['year'];
    final month = json['month'];
    final day = json['day'];
    final hour = json['hour'];
    final minute = json['minute'];
    if (year is! int ||
        month is! int ||
        day is! int ||
        hour is! int ||
        minute is! int) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'Wall clock fields must be integers.',
      );
    }
    return WallClockTime(year, month, day, hour, minute);
  }

  final int year;
  final int month;
  final int day;
  final int hour;
  final int minute;

  /// The fields as a UTC `DateTime`; used only for calendar arithmetic.
  DateTime get asDateTimeFields => DateTime.utc(year, month, day, hour, minute);

  WallClockTime addMinutes(int minutes) => WallClockTime.fromDateTime(
    asDateTimeFields.add(Duration(minutes: minutes)),
  );

  WallClockTime addDays(int days) =>
      WallClockTime.fromDateTime(asDateTimeFields.add(Duration(days: days)));

  /// Start of the day after this reading.
  WallClockTime get nextDayStart => WallClockTime.fromDateTime(
    DateTime.utc(year, month, day).add(const Duration(days: 1)),
  );

  Map<String, Object?> toJson() => freezeJsonMap(<String, Object?>{
    'year': year,
    'month': month,
    'day': day,
    'hour': hour,
    'minute': minute,
  });

  @override
  int compareTo(WallClockTime other) =>
      asDateTimeFields.compareTo(other.asDateTimeFields);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WallClockTime &&
          other.year == year &&
          other.month == month &&
          other.day == day &&
          other.hour == hour &&
          other.minute == minute;

  @override
  int get hashCode => Object.hash(year, month, day, hour, minute);

  @override
  String toString() =>
      '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-'
      '${day.toString().padLeft(2, '0')} '
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}
