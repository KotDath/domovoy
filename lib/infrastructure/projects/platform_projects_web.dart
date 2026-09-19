import '../../core/projects/repository.dart';
import 'project_platform_stack.dart';
import 'provisioners/web_unsupported_provisioner.dart';

ProjectPlatformStack createPlatformProjectStack() {
  final memory = InMemoryProjectRepository();
  return ProjectPlatformStack(
    repository: memory,
    catalog: memory,
    provisioner: WebUnsupportedProjectRootProvisioner(),
  );
}
