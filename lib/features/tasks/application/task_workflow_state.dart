import '../../../core/tasks/tasks.dart';

final class TaskWorkflowFailure {
  const TaskWorkflowFailure({required this.code, required this.message});

  final String code;
  final String message;
}

final class TaskCommandResult {
  const TaskCommandResult.accepted() : failure = null;
  const TaskCommandResult.rejected(this.failure);

  final TaskWorkflowFailure? failure;

  bool get isAccepted => failure == null;
}

final class TaskWorkflowState {
  const TaskWorkflowState({
    this.snapshot,
    this.failure,
    this.isInvokingAgent = false,
  });

  final TaskSnapshot? snapshot;
  final TaskWorkflowFailure? failure;
  final bool isInvokingAgent;

  TaskWorkflowState copyWith({
    Object? snapshot = _keep,
    Object? failure = _keep,
    bool? isInvokingAgent,
  }) => TaskWorkflowState(
    snapshot: identical(snapshot, _keep)
        ? this.snapshot
        : snapshot as TaskSnapshot?,
    failure: identical(failure, _keep)
        ? this.failure
        : failure as TaskWorkflowFailure?,
    isInvokingAgent: isInvokingAgent ?? this.isInvokingAgent,
  );
}

const _keep = Object();
