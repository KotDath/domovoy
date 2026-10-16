import 'dart:convert';
import 'dart:io';

import 'package:domovoy/core/projects/ids.dart';
import 'package:domovoy/infrastructure/projects/context/host_git_object_verifier_io.dart';
import 'package:domovoy/infrastructure/projects/context/local_project_context_io.dart';

/// Standalone child process so tests can exercise the actual inherited PATH.
Future<void> main(List<String> args) async {
  try {
    final service = LocalProjectContextService(
      resolveRoot: (_) async => args.single,
      selectGitVerifier: (_) async => const HostGitObjectVerifier(),
    );
    final context = await service.gitContext(ProjectId('path-probe'));
    stdout.writeln(jsonEncode(context.toJson()));
  } on Object {
    stderr.writeln('Git context rejected');
    exitCode = 1;
  }
}
