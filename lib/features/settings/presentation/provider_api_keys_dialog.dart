import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/llm/credentials.dart';
import '../../../core/llm/identifiers.dart';
import '../../../design_system/design_system.dart';
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
    this.embedded = false,
    super.key,
  });

  final ProviderCredentialStore store;
  final EnvironmentVariableReader environment;
  final ProviderModelCatalog? catalog;
  final bool embedded;

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
  Widget build(BuildContext context) {
    if (widget.embedded) return _embedded(context);
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: const Text('Провайдеры и API-ключи'),
        content: SizedBox(width: 430, child: _form(context)),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  Widget _embedded(BuildContext context) {
    final tokens = context.domovoyTheme;
    return Padding(
      key: const ValueKey('providers-view'),
      padding: DomovoyDimensions.pageInsets,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Провайдеры', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: DomovoyDimensions.space3),
          Text(
            'Провайдеры и доступные модели в одном месте.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: tokens.textSecondary),
          ),
          const SizedBox(height: DomovoyDimensions.space6),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 220,
                  child: ListView(
                    children: [
                      for (final entry in ApiKeyProviderManifest.entries)
                        DomovoyQuietButton(
                          key: ValueKey('provider-row:${entry.id}'),
                          expand: true,
                          tone: entry.id == _provider.id
                              ? DomovoyButtonTone.accent
                              : DomovoyButtonTone.quiet,
                          onPressed: _busy
                              ? null
                              : () {
                                  setState(() {
                                    _provider = entry;
                                    _message = null;
                                    _source = 'Проверка источника…';
                                    _key.clear();
                                  });
                                  _load();
                                },
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(entry.name),
                              Text(
                                entry.id == _provider.id ? _source : entry.name,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                VerticalDivider(
                  width: DomovoyDimensions.hairline,
                  color: tokens.border,
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: DomovoyDimensions.panelInsets,
                    child: _form(context, includePicker: false),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _form(BuildContext context, {bool includePicker = true}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (includePicker)
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
        if (includePicker) const SizedBox(height: DomovoyDimensions.space5),
        Text('Источник: $_source', key: const ValueKey('provider-key-source')),
        const SizedBox(height: DomovoyDimensions.space4),
        TextField(
          key: const ValueKey('provider-key-input'),
          controller: _key,
          enabled: !_busy,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(labelText: 'Новый API-ключ'),
        ),
        const SizedBox(height: DomovoyDimensions.space4),
        Row(
          children: [
            DomovoyQuietButton(
              key: const ValueKey('provider-save-key'),
              tone: DomovoyButtonTone.accent,
              onPressed: _busy ? null : _save,
              child: const Text('Сохранить'),
            ),
            if (_hasOverride)
              DomovoyQuietButton(
                key: const ValueKey('provider-remove-key'),
                onPressed: _busy ? null : _remove,
                child: const Text('Удалить ключ приложения'),
              ),
          ],
        ),
        if (kIsWeb)
          const Padding(
            padding: EdgeInsets.only(top: DomovoyDimensions.space4),
            child: Text(
              'В браузере API-ключ виден выполняющемуся коду. Для production нужен серверный прокси.',
            ),
          ),
        if (widget.catalog != null)
          DomovoyQuietButton(
            key: const ValueKey('provider-refresh-models'),
            onPressed: _busy ? null : _refresh,
            child: const Text('Обновить модели'),
          ),
        if (_message != null)
          Text(_message!, key: const ValueKey('provider-settings-message')),
        if (_busy) const LinearProgressIndicator(),
      ],
    );
  }
}
