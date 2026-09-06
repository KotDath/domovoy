final class DeepSeekModelSettings {
  const DeepSeekModelSettings({required this.reasoningEnabled});

  static const defaults = DeepSeekModelSettings(reasoningEnabled: true);

  final bool reasoningEnabled;

  DeepSeekModelSettings copyWith({bool? reasoningEnabled}) {
    return DeepSeekModelSettings(
      reasoningEnabled: reasoningEnabled ?? this.reasoningEnabled,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeepSeekModelSettings &&
          other.reasoningEnabled == reasoningEnabled;

  @override
  int get hashCode => reasoningEnabled.hashCode;

  @override
  String toString() =>
      'DeepSeekModelSettings(reasoningEnabled: $reasoningEnabled)';
}

abstract interface class DeepSeekModelSettingsStore {
  Future<DeepSeekModelSettings?> read();

  Future<void> write(DeepSeekModelSettings settings);
}

final class InMemoryDeepSeekModelSettingsStore
    implements DeepSeekModelSettingsStore {
  InMemoryDeepSeekModelSettingsStore([this.value]);

  DeepSeekModelSettings? value;
  int readCount = 0;
  int writeCount = 0;

  @override
  Future<DeepSeekModelSettings?> read() async {
    readCount++;
    return value;
  }

  @override
  Future<void> write(DeepSeekModelSettings settings) async {
    writeCount++;
    value = settings;
  }
}
