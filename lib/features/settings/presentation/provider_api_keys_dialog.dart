import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/llm/credentials.dart';
import '../../../core/llm/identifiers.dart';
import '../../../infrastructure/llm/discovery/provider_manifest.dart';
import '../../../infrastructure/llm/discovery/provider_model_catalog.dart';

Future<void> showProviderApiKeysDialog({
  required BuildContext context,
  required ProviderCredentialStore store,
  required EnvironmentVariableReader environment,
  ProviderModelCatalog? catalog,
}) => showDialog<void>(
  context: context,
  builder: (context) => ProviderApiKeysDialog(
    store: store,
    environment: environment,
    catalog: catalog,
  ),
);

class ProviderApiKeysDialog extends StatefulWidget {
  const ProviderApiKeysDialog({
    required this.store,
    required this.environment,
    this.catalog,
    super.key,
  });

  final ProviderCredentialStore store;
  final EnvironmentVariableReader environment;
  final ProviderModelCatalog? catalog;

  @override
  State<ProviderApiKeysDialog> createState() => _ProviderApiKeysDialogState();
}

class _ProviderApiKeysDialogState extends State<ProviderApiKeysDialog> {
  final _key = TextEditingController();
  ApiKeyProviderSpec _provider = ApiKeyProviderManifest.entries.first;
  String _source = '';
  String? _message;
  bool _hasOverride = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final selected = _provider;
    final saved = await widget.store.read(ProviderId(selected.id));
    if (!mounted || selected != _provider) return;
    final overridden = saved != null && saved.trim().isNotEmpty;
    final environment = widget.environment(selected.environmentVariable);
    setState(() {
      _hasOverride = overridden;
      _source = overridden
          ? 'Ключ приложения'
          : environment != null && environment.trim().isNotEmpty
          ? 'Переменная окружения ${selected.environmentVariable}'
          : 'Ключ не задан';
    });
  }

  Future<void> _save() async {
    final value = _key.text.trim();
    if (value.isEmpty) {
      setState(() => _message = 'Введите API-ключ.');
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.store.write(ProviderId(_provider.id), value);
      _key.clear();
      await _load();
      if (mounted) setState(() => _message = 'Ключ сохранён.');
    } on Object {
      if (mounted) setState(() => _message = 'Не удалось сохранить ключ.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    setState(() => _busy = true);
    try {
      await widget.store.delete(ProviderId(_provider.id));
      _key.clear();
      await _load();
      if (mounted) setState(() => _message = 'Ключ приложения удалён.');
    } on Object {
      if (mounted) setState(() => _message = 'Не удалось удалить ключ.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    try {
      final snapshot = await widget.catalog?.refresh();
      if (mounted) {
        setState(
          () => _message = snapshot == null
              ? 'Каталог недоступен.'
              : 'Каталог обновлён: ${snapshot.models.length} моделей.',
        );
      }
    } on Object {
      if (mounted) setState(() => _message = 'Не удалось обновить каталог.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: const Text('Провайдеры и API-ключи'),
      content: SizedBox(
        width: 430,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<ApiKeyProviderSpec>(
                key: const ValueKey('provider-settings-picker'),
                initialValue: _provider,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Провайдер'),
                items: [
                  for (final entry in ApiKeyProviderManifest.entries)
                    DropdownMenuItem(value: entry, child: Text(entry.name)),
                ],
                onChanged: _busy
                    ? null
                    : (provider) {
                        if (provider == null) return;
                        setState(() {
                          _provider = provider;
                          _message = null;
                          _source = 'Проверка источника…';
                          _key.clear();
                        });
                        _load();
                      },
              ),
              const SizedBox(height: 16),
              Text(
                'Источник: $_source',
                key: const ValueKey('provider-key-source'),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('provider-key-input'),
                controller: _key,
                enabled: !_busy,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Новый API-ключ',
                  border: OutlineInputBorder(),
                ),
              ),
              if (_hasOverride)
                TextButton.icon(
                  key: const ValueKey('provider-remove-key'),
                  onPressed: _busy ? null : _remove,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Удалить ключ приложения'),
                ),
              if (kIsWeb)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text(
                    'В браузере API-ключ виден выполняющемуся коду. Для production нужен серверный прокси.',
                  ),
                ),
              if (widget.catalog != null)
                TextButton.icon(
                  key: const ValueKey('provider-refresh-models'),
                  onPressed: _busy ? null : _refresh,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Обновить модели'),
                ),
              if (_message != null)
                Text(
                  _message!,
                  key: const ValueKey('provider-settings-message'),
                ),
              if (_busy) const LinearProgressIndicator(),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Закрыть'),
        ),
        FilledButton(
          key: const ValueKey('provider-save-key'),
          onPressed: _busy ? null : _save,
          child: const Text('Сохранить'),
        ),
      ],
    ),
  );
}
