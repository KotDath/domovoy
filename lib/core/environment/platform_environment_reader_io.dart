import 'dart:io';

import 'environment_reader.dart';

final class PlatformEnvironmentReader implements EnvironmentReader {
  const PlatformEnvironmentReader();

  @override
  String? read(String name) => Platform.environment[name];
}
