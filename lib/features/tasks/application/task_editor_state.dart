import '../../../core/agents/agents.dart';
import '../../../core/automation/automation.dart';
import '../../../core/mcp/mcp.dart';
import '../domain/task_editor_draft.dart';

/// Editable field of the task editor; used for per-field validation messages.
enum TaskEditorField { name, prompt, schedule, model, tools, delivery }

/// One tool offered to a scheduled task, grouped by its server.
final class TaskToolChoice {
  const TaskToolChoice({
    required this.toolId,
    required this.originalName,
    this.title,
    this.description,
  });

  /// B2 stable model-facing tool ID persisted in the task allowlist.
  final String toolId;
  final String originalName;
  final String? title;
  final String? description;
}

/// Tools of one MCP connection, as offered by the task editor.
final class TaskToolConnection {
  const TaskToolConnection({
    required this.connectionId,
    required this.alias,
    required this.connected,
    required this.tools,
    this.unavailableReason,
  });

  final McpConnectionId connectionId;
  final String alias;
  final bool connected;
  final String? unavailableReason;
  final List<TaskToolChoice> tools;
}

/// Observable state of one task editor session.
final class TaskEditorState {
  const TaskEditorState({
    this.draft = const TaskEditorDraft(),
    this.editingTaskId,
    this.editingRevision,
    this.errors = const <TaskEditorField, String>{},
    this.occurrences = const <DateTime>[],
    this.previewError,
    this.error,
    this.savedTask,
    this.presetNotice,
    this.busy = false,
    this.toolConnections = const <TaskToolConnection>[],
    this.chatOptions = const <AgentSessionSummary>[],
    this.chatsLoading = false,
  });

  final TaskEditorDraft draft;

  /// Task being edited; null means a new task is being created.
  final String? editingTaskId;
  final int? editingRevision;

  final Map<TaskEditorField, String> errors;

  /// Next occurrences of the current draft in UTC, up to three.
  final List<DateTime> occurrences;

  /// Why occurrences cannot be computed (cron, zone, past one-shot).
  final String? previewError;

  final String? error;
  final AutomationTask? savedTask;
  final String? presetNotice;
  final bool busy;
  final List<TaskToolConnection> toolConnections;
  final List<AgentSessionSummary> chatOptions;
  final bool chatsLoading;

  bool get isEditing => editingTaskId != null;

  TaskEditorState copyWith({
    TaskEditorDraft? draft,
    Object? editingTaskId = _unset,
    Object? editingRevision = _unset,
    Map<TaskEditorField, String>? errors,
    List<DateTime>? occurrences,
    Object? previewError = _unset,
    Object? error = _unset,
    Object? savedTask = _unset,
    Object? presetNotice = _unset,
    bool? busy,
    List<TaskToolConnection>? toolConnections,
    List<AgentSessionSummary>? chatOptions,
    bool? chatsLoading,
  }) {
    return TaskEditorState(
      draft: draft ?? this.draft,
      editingTaskId: identical(editingTaskId, _unset)
          ? this.editingTaskId
          : editingTaskId as String?,
      editingRevision: identical(editingRevision, _unset)
          ? this.editingRevision
          : editingRevision as int?,
      errors: errors ?? this.errors,
      occurrences: occurrences ?? this.occurrences,
      previewError: identical(previewError, _unset)
          ? this.previewError
          : previewError as String?,
      error: identical(error, _unset) ? this.error : error as String?,
      savedTask: identical(savedTask, _unset)
          ? this.savedTask
          : savedTask as AutomationTask?,
      presetNotice: identical(presetNotice, _unset)
          ? this.presetNotice
          : presetNotice as String?,
      busy: busy ?? this.busy,
      toolConnections: toolConnections ?? this.toolConnections,
      chatOptions: chatOptions ?? this.chatOptions,
      chatsLoading: chatsLoading ?? this.chatsLoading,
    );
  }
}

const Object _unset = Object();
