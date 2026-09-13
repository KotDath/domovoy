import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../domain/api_key_credentials.dart';
import '../domain/model_settings.dart';
import 'api_key_settings_controller.dart';

Future<void> showApiKeySettingsDialog({
  required BuildContext context,
  required ApiKeyOverrideStore overrideStore,
  required ApiKeyResolver resolver,
  required bool isWeb,
  DeepSeekModelSettingsStore? modelSettingsStore,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => ApiKeySettingsDialog(
      overrideStore: overrideStore,
      resolver: resolver,
      isWeb: isWeb,
      modelSettingsStore: modelSettingsStore,
    ),
  );
}

Future<void> showDeepSeekSettingsDialog({
  required BuildContext context,
  required ApiKeyOverrideStore overrideStore,
  required ApiKeyResolver resolver,
  required bool isWeb,
  required DeepSeekModelSettingsStore modelSettingsStore,
}) {
  return showApiKeySettingsDialog(
    context: context,
    overrideStore: overrideStore,
    resolver: resolver,
    isWeb: isWeb,
    modelSettingsStore: modelSettingsStore,
  );
}

class ApiKeySettingsDialog extends StatefulWidget {
  const ApiKeySettingsDialog({
    required this.overrideStore,
    required this.resolver,
    required this.isWeb,
    this.modelSettingsStore,
    super.key,
  });

  final ApiKeyOverrideStore overrideStore;
  final ApiKeyResolver resolver;
  final bool isWeb;
  final DeepSeekModelSettingsStore? modelSettingsStore;

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
      modelSettingsStore: widget.modelSettingsStore,
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
    // Any persistence in flight (API key or reasoning) blocks dismissal so
    // callers awaiting the dialog always observe completed writes.
    final busy = state.isSaving || state.isReasoningSaving;

    return PopScope(
      canPop: !busy,
      child: AlertDialog(
        title: const Text('Настройки DeepSeek'),
        content: SizedBox(
          width: DomovoyDimensions.settingsDialogWidth,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (state.isLoading) const LinearProgressIndicator(),
                Text(
                  'Учётные данные',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: DomovoyDimensions.space3),
                Text(
                  _sourceDescription(state.source),
                  key: const ValueKey('api-key-source'),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: DomovoyDimensions.space5),
                TextField(
                  key: const ValueKey('api-key-input'),
                  controller: _keyController,
                  enabled: !busy,
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
                  onSubmitted: busy ? null : (_) => _save(),
                ),
                if (state.hasApplicationOverride) ...[
                  const SizedBox(height: DomovoyDimensions.space3),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const ValueKey('remove-api-key'),
                      onPressed: busy ? null : _remove,
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Удалить ключ приложения'),
                    ),
                  ),
                ],
                if (widget.isWeb) ...[
                  const SizedBox(height: DomovoyDimensions.space4),
                  Container(
                    key: const ValueKey('web-key-warning'),
                    padding: DomovoyDimensions.panelInsets,
                    decoration: BoxDecoration(
                      color: colorScheme.tertiaryContainer,
                      borderRadius: BorderRadius.circular(
                        DomovoyDimensions.radiusMedium,
                      ),
                    ),
                    child: const Text(
                      'Браузерное приложение не может скрыть ключ от кода, '
                      'выполняющегося в браузере. Для production нужен серверный '
                      'прокси.',
                    ),
                  ),
                ],
                const SizedBox(height: DomovoyDimensions.space6),
                Text('Модель', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: DomovoyDimensions.space3),
                SwitchListTile(
                  key: const ValueKey('reasoning-switch'),
                  value: state.reasoningEnabled,
                  onChanged: state.isReasoningSaving || state.isLoading
                      ? null
                      : (value) => _settings.setReasoningEnabled(value),
                  title: const Text('Режим Reasoning'),
                  subtitle: Text(
                    state.reasoningEnabled
                        ? 'Включено: thinking.type=enabled, reasoning_effort=high.'
                        : 'Выключено: thinking.type=disabled без reasoning_effort.',
                  ),
                  contentPadding: EdgeInsets.zero,
                ),
                if (state.isReasoningSaving) ...[
                  const SizedBox(height: DomovoyDimensions.space2),
                  const LinearProgressIndicator(
                    key: ValueKey('reasoning-saving'),
                  ),
                ],
                if (state.message != null) ...[
                  const SizedBox(height: DomovoyDimensions.space4),
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
            onPressed: busy ? null : () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
          FilledButton(
            key: const ValueKey('save-api-key'),
            onPressed: busy ? null : _save,
            child: state.isSaving
                ? const SizedBox.square(
                    dimension: DomovoyDimensions.progressSmall,
                    child: CircularProgressIndicator(
                      strokeWidth: DomovoyDimensions.progressStroke,
                    ),
                  )
                : const Text('Сохранить'),
          ),
        ],
      ),
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
