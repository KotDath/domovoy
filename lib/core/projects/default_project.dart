import 'ids.dart';

/// Display name of the protected, application-managed default project.
const defaultProjectName = 'По умолчанию';

/// Identity of the protected default project.
final ProjectId defaultProjectId = ProjectId.defaultProject;

/// Root identity of the default project's application-managed sandbox.
final ProjectRootId defaultProjectRootId = ProjectRootId(
  ProjectId.defaultProjectValue,
);
