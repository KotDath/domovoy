import '../../core/projects/catalog.dart';
import '../../core/projects/grants.dart';
import '../../core/projects/provisioning.dart';
import '../../core/projects/repository.dart';

final class ProjectPlatformStack {
  const ProjectPlatformStack({
    required this.repository,
    required this.catalog,
    required this.provisioner,
    this.grants,
  });

  final ProjectRepository repository;
  final ProjectCatalog catalog;
  final ProjectRootProvisioner provisioner;
  final ProjectDirectoryGrantStore? grants;
}
