abstract interface class EnvironmentReader {
  String? read(String name);
}

final class MapEnvironmentReader implements EnvironmentReader {
  const MapEnvironmentReader(this.values);

  final Map<String, String> values;

  @override
  String? read(String name) => values[name];
}
