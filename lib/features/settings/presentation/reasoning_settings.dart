import 'package:flutter/foundation.dart';

import '../domain/model_settings.dart';

/// Observable holder for the persisted DeepSeek reasoning setting.
///
/// Missing values and read failures fall back to
/// [DeepSeekModelSettings.defaults].
final class ReasoningSettings extends ChangeNotifier {
  ReasoningSettings({required DeepSeekModelSettingsStore store})
    : _store = store;

  final DeepSeekModelSettingsStore _store;
  bool _enabled = DeepSeekModelSettings.defaults.reasoningEnabled;
  bool _loaded = false;
  bool _disposed = false;

  bool get reasoningEnabled => _enabled;
  bool get isLoaded => _loaded;

  Future<void> load() async {
    try {
      final stored = await _store.read();
      _enabled =
          stored?.reasoningEnabled ??
          DeepSeekModelSettings.defaults.reasoningEnabled;
    } on Object {
      _enabled = DeepSeekModelSettings.defaults.reasoningEnabled;
    }
    _loaded = true;
    _notify();
  }

  Future<bool> setEnabled(bool value) async {
    try {
      await _store.write(DeepSeekModelSettings(reasoningEnabled: value));
    } on Object {
      return false;
    }
    _enabled = value;
    _loaded = true;
    _notify();
    return true;
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
