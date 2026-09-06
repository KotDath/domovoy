import 'package:flutter/foundation.dart';

import '../domain/api_key_credentials.dart';

@immutable
final class ApiKeySettingsState {
  const ApiKeySettingsState({
    this.isLoading = false,
    this.isSaving = false,
    this.source = ApiKeySource.missing,
    this.hasApplicationOverride = false,
    this.inputError,
    this.message,
  });

  final bool isLoading;
  final bool isSaving;
  final ApiKeySource source;
  final bool hasApplicationOverride;
  final String? inputError;
  final String? message;
}

final class ApiKeySettingsController extends ChangeNotifier {
  ApiKeySettingsController({
    required ApiKeyOverrideStore overrideStore,
    required ApiKeyResolver resolver,
  }) : _overrideStore = overrideStore,
       _resolver = resolver;

  final ApiKeyOverrideStore _overrideStore;
  final ApiKeyResolver _resolver;
  ApiKeySettingsState _state = const ApiKeySettingsState(isLoading: true);
  bool _disposed = false;

  ApiKeySettingsState get state => _state;

  Future<void> load() async {
    _state = ApiKeySettingsState(
      isLoading: true,
      source: _state.source,
      hasApplicationOverride: _state.hasApplicationOverride,
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

  void clearInputError() {
    if (_state.inputError == null) {
      return;
    }
    _state = ApiKeySettingsState(
      source: _state.source,
      hasApplicationOverride: _state.hasApplicationOverride,
      message: _state.message,
    );
    _notifyListeners();
  }

  void _setSaving() {
    _state = ApiKeySettingsState(
      isSaving: true,
      source: _state.source,
      hasApplicationOverride: _state.hasApplicationOverride,
    );
    _notifyListeners();
  }

  Future<void> _refresh({required String? message}) async {
    try {
      final status = await _resolver.status();
      _state = ApiKeySettingsState(
        source: status.source,
        hasApplicationOverride: status.hasApplicationOverride,
        message: message,
      );
    } on Object {
      _setStorageFailure(notify: false);
    }
    _notifyListeners();
  }

  void _setStorageFailure({bool notify = true}) {
    _state = ApiKeySettingsState(
      source: _state.source,
      hasApplicationOverride: _state.hasApplicationOverride,
      message: 'Не удалось обратиться к защищённому хранилищу ключа.',
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
