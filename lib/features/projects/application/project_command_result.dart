import '../../../core/projects/errors.dart';
import '../../../core/projects/record.dart';

enum ProjectCommandStatus {
  succeeded,
  cancelled,
  conflict,
  failed,
  unsupported,
}

final class ProjectCommandResult {
  const ProjectCommandResult._({
    required this.status,
    this.project,
    this.error,
    this.cleanupWarning = false,
  });

  const ProjectCommandResult.succeeded({ProjectRecord? project})
    : this._(status: ProjectCommandStatus.succeeded, project: project);

  const ProjectCommandResult.cancelled()
    : this._(status: ProjectCommandStatus.cancelled);

  const ProjectCommandResult.conflict(ProjectError error)
    : this._(status: ProjectCommandStatus.conflict, error: error);

  const ProjectCommandResult.failed(
    ProjectError error, {
    bool cleanupWarning = false,
  }) : this._(
         status: ProjectCommandStatus.failed,
         error: error,
         cleanupWarning: cleanupWarning,
       );

  const ProjectCommandResult.unsupported()
    : this._(status: ProjectCommandStatus.unsupported, error: null);

  final ProjectCommandStatus status;
  final ProjectRecord? project;
  final ProjectError? error;
  final bool cleanupWarning;

  bool get isSuccess => status == ProjectCommandStatus.succeeded;
}
