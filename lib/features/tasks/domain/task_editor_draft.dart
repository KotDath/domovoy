import '../../../core/automation/automation.dart';
import '../../../core/llm/identifiers.dart';

/// Which schedule form the editor currently edits.
enum TaskScheduleKind { oneShot, cron }

/// Editable fields of one automation task in the tasks editor (B8).
///
/// The draft never touches the stored task: the editor validates it and only
/// then calls [AutomationService.createTask] or [AutomationService.updateTask].
/// Identity, revision and state stay with the service.
final class TaskEditorDraft {
  const TaskEditorDraft({
    this.name = '',
    this.prompt = '',
    this.scheduleKind = TaskScheduleKind.cron,
    this.cronExpression = '*/5 * * * *',
    this.timeZoneId = 'UTC',
    this.oneShotLocal,
    this.model,
    this.allowedToolIds = const <String>[],
    this.delivery = const AutomationDelivery.tasks(),
  });

  /// Builds the draft of an existing task for editing.
  factory TaskEditorDraft.fromTask(AutomationTask task) {
    final schedule = task.schedule;
    if (schedule is CronSchedule) {
      return TaskEditorDraft(
        name: task.name,
        prompt: task.prompt,
        scheduleKind: TaskScheduleKind.cron,
        cronExpression: schedule.expression,
        timeZoneId: schedule.timeZoneId,
        model: task.model,
        allowedToolIds: task.allowedToolIds,
        delivery: task.delivery,
      );
    }
    final oneShot = schedule as OneShotSchedule;
    return TaskEditorDraft(
      name: task.name,
      prompt: task.prompt,
      scheduleKind: TaskScheduleKind.oneShot,
      oneShotLocal: oneShot.atUtc,
      timeZoneId: task.schedule.timeZoneId ?? 'UTC',
      model: task.model,
      allowedToolIds: task.allowedToolIds,
      delivery: task.delivery,
    );
  }

  final String name;
  final String prompt;
  final TaskScheduleKind scheduleKind;

  /// Five-field cron expression; used when [scheduleKind] is cron.
  final String cronExpression;

  /// Explicit IANA zone of the schedule.
  final String timeZoneId;

  /// Wall-clock date/time of a one-shot task, interpreted in [timeZoneId].
  ///
  /// Only the calendar fields are read; the value is never treated as an
  /// absolute instant, so the device time zone cannot shift the result.
  final DateTime? oneShotLocal;

  final ModelRef? model;
  final List<String> allowedToolIds;
  final AutomationDelivery delivery;

  TaskEditorDraft copyWith({
    String? name,
    String? prompt,
    TaskScheduleKind? scheduleKind,
    String? cronExpression,
    String? timeZoneId,
    Object? oneShotLocal = _unset,
    Object? model = _unset,
    Iterable<String>? allowedToolIds,
    AutomationDelivery? delivery,
  }) {
    return TaskEditorDraft(
      name: name ?? this.name,
      prompt: prompt ?? this.prompt,
      scheduleKind: scheduleKind ?? this.scheduleKind,
      cronExpression: cronExpression ?? this.cronExpression,
      timeZoneId: timeZoneId ?? this.timeZoneId,
      oneShotLocal: identical(oneShotLocal, _unset)
          ? this.oneShotLocal
          : oneShotLocal as DateTime?,
      model: identical(model, _unset) ? this.model : model as ModelRef?,
      allowedToolIds: List<String>.unmodifiable(
        allowedToolIds ?? this.allowedToolIds,
      ),
      delivery: delivery ?? this.delivery,
    );
  }

  /// Builds the schedule of this draft, resolving a one-shot wall clock.
  ///
  /// Throws [AutomationException] with a user-facing message when the wall
  /// clock does not exist in the zone (spring DST gap) or is missing.
  AutomationSchedule buildSchedule(AutomationTimeZones zones) {
    switch (scheduleKind) {
      case TaskScheduleKind.cron:
        return AutomationSchedule.cron(
          expression: cronExpression,
          timeZoneId: timeZoneId,
        );
      case TaskScheduleKind.oneShot:
        final local = oneShotLocal;
        if (local == null) {
          throwAutomation(
            AutomationErrorKind.invalidSchedule,
            'Укажите дату и время разового запуска.',
          );
        }
        final wall = WallClockTime(
          local.year,
          local.month,
          local.day,
          local.hour,
          local.minute,
        );
        final instants = zones.resolveLocal(timeZoneId, wall);
        if (instants.isEmpty) {
          throwAutomation(
            AutomationErrorKind.invalidSchedule,
            'В часовом поясе "$timeZoneId" такого местного времени не '
            'существует (переход на летнее время). Выберите другое время.',
          );
        }
        return AutomationSchedule.oneShot(instants.first);
    }
  }

  /// Validated task fields for the service, after editor validation passed.
  AutomationTaskDraft toTaskDraft(AutomationTimeZones zones) {
    final selectedModel = model;
    if (selectedModel == null) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'Выберите модель для задачи.',
      );
    }
    if (allowedToolIds.isEmpty) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'Выберите хотя бы один разрешённый инструмент.',
      );
    }
    return AutomationTaskDraft(
      name: name,
      prompt: prompt,
      schedule: buildSchedule(zones),
      model: selectedModel,
      allowedToolIds: allowedToolIds,
      delivery: delivery,
    );
  }
}

const Object _unset = Object();
