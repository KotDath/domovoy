import '../llm/cancellation.dart';
import '../rag/models.dart';
import 'ids.dart';

const projectDocumentationCorpus = 'project-docs-v1';

/// Flutter-free seam shared by interactive and future headless composition.
abstract interface class ProjectContextService {
  Future<List<RagDocument>> scanDocumentation(
    ProjectId project,
    CancellationToken cancellation,
  );
  Future<ProjectGitContext> gitContext(ProjectId project);
  Future<void> importArchive(
    ProjectId project,
    List<int> bytes,
    CancellationToken cancellation,
  );
}

final class ProjectGitContext {
  const ProjectGitContext({required this.head, this.branch});
  final String head;
  final String? branch;
  Map<String, Object?> toJson() => {
    'branch': branch,
    'head': head,
    'detached': branch == null,
  };
}

String? projectHelpQuestion(String input) {
  final match = RegExp(r'^/help(?:\s+([\s\S]*))?$').firstMatch(input.trim());
  if (match == null) return null;
  final question = match[1]?.trim() ?? '';
  return question.isEmpty
      ? 'Explain this project’s purpose, structure and main components using its documentation.'
      : question;
}
