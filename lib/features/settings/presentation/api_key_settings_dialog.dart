import 'package:flutter/material.dart';

import '../domain/api_key_credentials.dart';
import 'api_key_settings_controller.dart';

Future<void> showApiKeySettingsDialog({
  required BuildContext context,
  required ApiKeyOverrideStore overrideStore,
  required ApiKeyResolver resolver,
  required bool isWeb,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => ApiKeySettingsDialog(
      overrideStore: overrideStore,
      resolver: resolver,
      isWeb: isWeb,
    ),
  );
}

class ApiKeySettingsDialog extends StatefulWidget {
  const ApiKeySettingsDialog({
    required this.overrideStore,
    required this.resolver,
    required this.isWeb,
    super.key,
  });

  final ApiKeyOverrideStore overrideStore;
  final ApiKeyResolver resolver;
  final bool isWeb;

  @override
  State<ApiKeySettingsDialog> createState() => _ApiKeySettingsDialogState();
}

class _ApiKeySettingsDialogState extends State<ApiKeySettingsDialog> {
  late final ApiKeySettingsController _settings;
  final _keyController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _settings = ApiKeySettingsController(
      overrideStore: widget.overrideStore,
      resolver: widget.resolver,
    )..addListener(_rebuild);
    _settings.load();
  }

  @override
  void dispose() {
    _settings
      ..removeListener(_rebuild)
      ..dispose();
    _keyController.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = _settings.state;
    final colorScheme = Theme.of(context).colorScheme;

    return AlertDialog(
      title: const Text('API-ключ DeepSeek'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (state.isLoading) const LinearProgressIndicator(),
              Text(
                _sourceDescription(state.source),
                key: const ValueKey('api-key-source'),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              TextField(
                key: const ValueKey('api-key-input'),
                controller: _keyController,
                enabled: !state.isSaving,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                autofillHints: const [AutofillHints.password],
                decoration: InputDecoration(
                  labelText: 'Новый API-ключ',
                  hintText: 'Вставьте ключ для замены текущего',
                  errorText: state.inputError,
                  border: const OutlineInputBorder(),
                ),
                onChanged: (_) => _settings.clearInputError(),
                onSubmitted: state.isSaving ? null : (_) => _save(),
              ),
              if (state.hasApplicationOverride) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const ValueKey('remove-api-key'),
                    onPressed: state.isSaving ? null : _remove,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Удалить ключ приложения'),
                  ),
                ),
              ],
              if (widget.isWeb) ...[
                const SizedBox(height: 12),
                Container(
                  key: const ValueKey('web-key-warning'),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colorScheme.tertiaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    'Браузерное приложение не может скрыть ключ от кода, '
                    'выполняющегося в браузере. Для production нужен серверный '
                    'прокси.',
                  ),
                ),
              ],
              if (state.message != null) ...[
                const SizedBox(height: 12),
                Text(
                  state.message!,
                  key: const ValueKey('api-key-settings-message'),
                  style: TextStyle(color: colorScheme.primary),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: state.isSaving ? null : () => Navigator.pop(context),
          child: const Text('Закрыть'),
        ),
        FilledButton(
          key: const ValueKey('save-api-key'),
          onPressed: state.isSaving ? null : _save,
          child: state.isSaving
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Сохранить'),
        ),
      ],
    );
  }

  Future<void> _save() async {
    final saved = await _settings.save(_keyController.text);
    if (saved) {
      _keyController.clear();
    }
  }

  Future<void> _remove() async {
    final removed = await _settings.remove();
    if (removed) {
      _keyController.clear();
    }
  }

  static String _sourceDescription(ApiKeySource source) => switch (source) {
    ApiKeySource.applicationOverride =>
      'Активный источник: ключ из настроек приложения. Значение скрыто.',
    ApiKeySource.environment =>
      'Активный источник: переменная окружения DEEPSEEK_API_KEY.',
    ApiKeySource.missing =>
      'Ключ не настроен. Добавьте его здесь или задайте '
          'DEEPSEEK_API_KEY в окружении.',
  };
}
