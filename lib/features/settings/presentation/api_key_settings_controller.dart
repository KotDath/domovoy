import 'package:flutter/foundation.dart';

import '../domain/api_key_credentials.dart';
import '../domain/model_settings.dart';

@immutable
final class ApiKeySettingsState {
  const ApiKeySettingsState({
    this.isLoading = false,
    this.isSaving = false,
    this.source = ApiKeySource.missing,
    this.hasApplicationOverride = false,
    this.inputError,
    this.message,
    this.reasoningEnabled = true,
    this.isReasoningSaving = false,
  });

  final bool isLoading;
  final bool isSaving;
  final ApiKeySource source;
  final bool hasApplicationOverride;
  final String? inputError;
  final String? message;
  final bool reasoningEnabled;
  final bool isReasoningSaving;
}

final class ApiKeySettingsController extends ChangeNotifier {
  ApiKeySettingsController({
    required ApiKeyOverrideStore overrideStore,
    required ApiKeyResolver resolver,
    DeepSeekModelSettingsStore? modelSettingsStore,
  }) : _overrideStore = overrideStore,
       _resolver = resolver,
       _modelSettingsStore =
           modelSettingsStore ?? InMemoryDeepSeekModelSettingsStore();

  final ApiKeyOverrideStore _overrideStore;
  final ApiKeyResolver _resolver;
  final DeepSeekModelSettingsStore _modelSettingsStore;
  ApiKeySettingsState _state = const ApiKeySettingsState(isLoading: true);
  bool _disposed = false;

  ApiKeySettingsState get state => _state;

  Future<void> load() async {
    _state = ApiKeySettingsState(
      isLoading: true,
      source: _state.source,
      hasApplicationOverride: _state.hasApplicationOverride,
      reasoningEnabled: _state.reasoningEnabled,
    );
    _notifyListeners();
    await _refresh(message: null);
  }

  Future<bool> save(String rawValue) async {
    final value = rawValue.trim();
    if (value.isEmpty) {
      _state = ApiKeySettingsState(
        source: _state.source,
        hasApplicationOverride: _state.hasApplicationOverride,
        inputError: 'Введите непустой API-ключ.',
        reasoningEnabled: _state.reasoningEnabled,
      );
      _notifyListeners();
      return false;
    }

    _setSaving();
    try {
      await _overrideStore.write(value);
      await _refresh(message: 'Ключ сохранён в настройках приложения.');
      return true;
    } on Object {
      _setStorageFailure();
      return false;
    }
  }

  Future<bool> remove() async {
    _setSaving();
    try {
      await _overrideStore.delete();
      await _refresh(message: 'Ключ приложения удалён.');
      return true;
    } on Object {
      _setStorageFailure();
      return false;
    }
  }

  Future<bool> setReasoningEnabled(bool enabled) async {
    _state = ApiKeySettingsState(
      source: _state.source,
      hasApplicationOverride: _state.hasApplicationOverride,
      inputError: _state.inputError,
      message: _state.message,
      reasoningEnabled: _state.reasoningEnabled,
      isReasoningSaving: true,
    );
    _notifyListeners();
    try {
      await _modelSettingsStore.write(
        DeepSeekModelSettings(reasoningEnabled: enabled),
      );
      _state = ApiKeySettingsState(
        source: _state.source,
        hasApplicationOverride: _state.hasApplicationOverride,
        message: _state.message,
        reasoningEnabled: enabled,
      );
      _notifyListeners();
      return true;
    } on Object {
      _state = ApiKeySettingsState(
        source: _state.source,
        hasApplicationOverride: _state.hasApplicationOverride,
        message: 'Не удалось сохранить настройки модели.',
        reasoningEnabled: _state.reasoningEnabled,
      );
      _notifyListeners();
      return false;
    }
  }

  void clearInputError() {
    if (_state.inputError == null) {
      return;
    }
    _state = ApiKeySettingsState(
      source: _state.source,
      hasApplicationOverride: _state.hasApplicationOverride,
      message: _state.message,
      reasoningEnabled: _state.reasoningEnabled,
    );
    _notifyListeners();
  }

  void _setSaving() {
    _state = ApiKeySettingsState(
      isSaving: true,
      source: _state.source,
      hasApplicationOverride: _state.hasApplicationOverride,
      reasoningEnabled: _state.reasoningEnabled,
    );
    _notifyListeners();
  }

  Future<void> _refresh({required String? message}) async {
    String? effectiveMessage = message;
    bool reasoningEnabled = _state.reasoningEnabled;
    try {
      final status = await _resolver.status();
      try {
        final stored = await _modelSettingsStore.read();
        reasoningEnabled =
            stored?.reasoningEnabled ??
            DeepSeekModelSettings.defaults.reasoningEnabled;
      } on Object {
        effectiveMessage =
            message ??
            'Не удалось загрузить настройки модели. Используется значение по умолчанию.';
      }
      _state = ApiKeySettingsState(
        source: status.source,
        hasApplicationOverride: status.hasApplicationOverride,
        message: effectiveMessage,
        reasoningEnabled: reasoningEnabled,
      );
    } on Object {
      _setStorageFailure(notify: false);
      // Preserve reasoning selection even when credential lookup fails.
      _state = ApiKeySettingsState(
        source: _state.source,
        hasApplicationOverride: _state.hasApplicationOverride,
        message: _state.message,
        reasoningEnabled: _state.reasoningEnabled,
      );
    }
    _notifyListeners();
  }

  void _setStorageFailure({bool notify = true}) {
    _state = ApiKeySettingsState(
      source: _state.source,
      hasApplicationOverride: _state.hasApplicationOverride,
      message: 'Не удалось обратиться к защищённому хранилищу ключа.',
      reasoningEnabled: _state.reasoningEnabled,
    );
    if (notify) {
      _notifyListeners();
    }
  }

  void _notifyListeners() {
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
