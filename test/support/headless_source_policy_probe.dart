// String predicates only. No source/store file reads or generated programs.
import 'dart:convert';
import 'dart:io';

import 'package:domovoy/infrastructure/headless/project_sources_io.dart';

Future<void> main() async {
  final paths = (jsonDecode(await utf8.decoder.bind(stdin).join()) as List)
      .cast<String>();
  print(
    jsonEncode({
      for (final path in paths) path: ProjectSourcePolicy.permits(path),
    }),
  );
}
