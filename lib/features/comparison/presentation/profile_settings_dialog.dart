import 'package:flutter/material.dart';

import '../../../core/environment/environment_reader.dart';
import '../../settings/domain/api_key_credentials.dart';
import '../data/profile_credential_resolver.dart';
import '../domain/chat_model_profile.dart';
import 'comparison_profile_catalog.dart';
import 'profile_settings_controller.dart';

Future<void> showComparisonProfileSettingsDialog({
  required BuildContext context,
  required ComparisonProfileCatalog catalog,
  required ApiKeyResolver sharedDeepSeekResolver,
  required ProfileApiKeyOverrideStore profileOverrideStore,
  required EnvironmentReader environment,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => ComparisonProfileSettingsDialog(
      catalog: catalog,
      sharedDeepSeekResolver: sharedDeepSeekResolver,
      profileOverrideStore: profileOverrideStore,
      environment: environment,
    ),
  );
}

class ComparisonProfileSettingsDialog extends StatefulWidget {
  const ComparisonProfileSettingsDialog({
    required this.catalog,
    required this.sharedDeepSeekResolver,
    required this.profileOverrideStore,
    required this.environment,
    super.key,
  });

  final ComparisonProfileCatalog catalog;
  final ApiKeyResolver sharedDeepSeekResolver;
  final ProfileApiKeyOverrideStore profileOverrideStore;
  final EnvironmentReader environment;

  @override
  State<ComparisonProfileSettingsDialog> createState() =>
      _ComparisonProfileSettingsDialogState();
}

class _ComparisonProfileSettingsDialogState
    extends State<ComparisonProfileSettingsDialog>
    with SingleTickerProviderStateMixin {
  late final ProfileSettingsController _settings;
  late final TabController _tabs;
  late final List<TextEditingController> _keys;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: kComparisonLaneCount, vsync: this)
      ..addListener(_rebuild);
    _keys = List<TextEditingController>.generate(
      kComparisonLaneCount,
      (_) => TextEditingController(),
    );
    _settings = ProfileSettingsController(
      catalog: widget.catalog,
      sharedDeepSeekResolver: widget.sharedDeepSeekResolver,
      profileOverrideStore: widget.profileOverrideStore,
      environment: widget.environment,
    )..addListener(_rebuild);
    _settings.load();
  }

  @override
  void dispose() {
    _settings
      ..removeListener(_rebuild)
      ..dispose();
    _tabs
      ..removeListener(_rebuild)
      ..dispose();
    for (final key in _keys) {
      key.dispose();
    }
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
    final busy = state.busy;
    return PopScope(
      canPop: !busy,
      child: AlertDialog(
        title: const Text('Профили сравнения'),
        content: SizedBox(
          width: 640,
          height: 560,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (busy) const LinearProgressIndicator(),
              TabBar(
                controller: _tabs,
                isScrollable: true,
                tabs: [
                  for (var i = 0; i < kComparisonLaneCount; i++)
                    Tab(
                      key: ValueKey('profile-tab-$i'),
                      text: comparisonTierLabel(state.profiles[i].tier),
                    ),
                ],
              ),
              Expanded(
                child: IndexedStack(
                  index: _tabs.index,
                  children: [
                    for (var i = 0; i < kComparisonLaneCount; i++)
                      KeyedSubtree(
                        key: ValueKey('profile-editor-$i-${state.formEpoch}'),
                        child: _ProfileEditor(
                          index: i,
                          profile: state.profiles[i],
                          draft: state.drafts[i],
                          status: state.statuses[i],
                          error: state.errors[i],
                          enabled: !busy,
                          keyController: _keys[i],
                          onChanged: (draft) => _settings.updateDraft(i, draft),
                          onSave: () => _saveProfile(i),
                          onSaveKey: () => _saveKey(i),
                          onRemoveKey: state.statuses[i].hasApplicationOverride
                              ? () => _removeKey(i)
                              : null,
                        ),
                      ),
                  ],
                ),
              ),
              if (state.message != null) ...[
                const SizedBox(height: 8),
                Text(
                  state.message!,
                  key: const ValueKey('profile-settings-message'),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('reset-day5-profiles'),
            onPressed: busy ? null : _reset,
            child: const Text('Сбросить профили'),
          ),
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveProfile(int index) async {
    await _settings.save(index);
  }

  Future<void> _saveKey(int index) async {
    final saved = await _settings.saveKey(index, _keys[index].text);
    if (saved) {
      _keys[index].clear();
    }
  }

  Future<void> _removeKey(int index) async {
    final removed = await _settings.removeKey(index);
    if (removed) {
      _keys[index].clear();
    }
  }

  Future<void> _reset() async {
    final reset = await _settings.reset();
    if (reset) {
      for (final key in _keys) {
        key.clear();
      }
    }
  }
}

class _ProfileEditor extends StatelessWidget {
  const _ProfileEditor({
    required this.index,
    required this.profile,
    required this.draft,
    required this.status,
    required this.enabled,
    required this.keyController,
    required this.onChanged,
    required this.onSave,
    required this.onSaveKey,
    required this.onRemoveKey,
    this.error,
  });

  final int index;
  final ChatModelProfile profile;
  final ProfileDraft draft;
  final ApiKeyStatus status;
  final String? error;
  final bool enabled;
  final TextEditingController keyController;
  final ValueChanged<ProfileDraft> onChanged;
  final VoidCallback onSave;
  final VoidCallback onSaveKey;
  final VoidCallback? onRemoveKey;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(top: 12),
      children: [
        Text('${comparisonTierLabel(profile.tier)} · ${profile.id}'),
        const SizedBox(height: 8),
        Text(
          _statusText(status, profile),
          key: ValueKey('profile-key-source-$index'),
        ),
        const SizedBox(height: 8),
        TextField(
          key: ValueKey('profile-key-input-$index'),
          controller: keyController,
          enabled:
              enabled && draft.authentication != ProfileAuthenticationMode.none,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(
            labelText: 'Новый API-ключ',
            hintText: 'Поле всегда пустое',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            FilledButton(
              key: ValueKey('save-profile-$index'),
              onPressed: enabled ? onSave : null,
              child: const Text('Сохранить профиль'),
            ),
            OutlinedButton(
              key: ValueKey('save-profile-key-$index'),
              onPressed:
                  enabled &&
                      draft.authentication != ProfileAuthenticationMode.none
                  ? onSaveKey
                  : null,
              child: const Text('Сохранить ключ'),
            ),
            if (onRemoveKey != null)
              TextButton(
                key: ValueKey('remove-profile-key-$index'),
                onPressed: enabled ? onRemoveKey : null,
                child: const Text('Удалить ключ'),
              ),
          ],
        ),
        if (error != null) ...[
          const SizedBox(height: 8),
          Text(
            error!,
            key: ValueKey('profile-error-$index'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 8),
        _field(
          key: ValueKey('profile-endpoint-$index'),
          label: 'Адрес Chat Completions',
          value: draft.endpoint,
          enabled: enabled,
          onChanged: (value) => onChanged(draft.copyWith(endpoint: value)),
        ),
        _field(
          key: ValueKey('profile-model-$index'),
          label: 'Модель',
          value: draft.modelId,
          enabled: enabled,
          onChanged: (value) => onChanged(draft.copyWith(modelId: value)),
        ),
        DropdownButtonFormField<ChatRequestDialect>(
          key: ValueKey('profile-dialect-$index'),
          initialValue: draft.dialect,
          decoration: const InputDecoration(labelText: 'Диалект'),
          items: const [
            DropdownMenuItem(
              value: ChatRequestDialect.generic,
              child: Text('generic'),
            ),
            DropdownMenuItem(
              value: ChatRequestDialect.ollama,
              child: Text('ollama'),
            ),
            DropdownMenuItem(
              value: ChatRequestDialect.deepSeek,
              child: Text('deepSeek'),
            ),
          ],
          onChanged: enabled
              ? (value) {
                  if (value != null) {
                    onChanged(draft.copyWith(dialect: value));
                  }
                }
              : null,
        ),
        DropdownButtonFormField<ProfileAuthenticationMode>(
          key: ValueKey('profile-auth-$index'),
          initialValue: draft.authentication,
          decoration: const InputDecoration(labelText: 'Аутентификация'),
          items: const [
            DropdownMenuItem(
              value: ProfileAuthenticationMode.none,
              child: Text('без ключа'),
            ),
            DropdownMenuItem(
              value: ProfileAuthenticationMode.sharedDeepSeek,
              child: Text('общий DeepSeek'),
            ),
            DropdownMenuItem(
              value: ProfileAuthenticationMode.profileBearer,
              child: Text('ключ профиля'),
            ),
          ],
          onChanged: enabled
              ? (value) {
                  if (value != null) {
                    onChanged(draft.copyWith(authentication: value));
                  }
                }
              : null,
        ),
        _field(
          key: ValueKey('profile-env-$index'),
          label: 'Переменная окружения',
          value: draft.environmentVariableName,
          enabled: enabled,
          onChanged: (value) =>
              onChanged(draft.copyWith(environmentVariableName: value)),
        ),
        _field(
          key: ValueKey('profile-source-$index'),
          label: 'Ссылка на источник',
          value: draft.sourceUrl,
          enabled: enabled,
          onChanged: (value) => onChanged(draft.copyWith(sourceUrl: value)),
        ),
        _field(
          key: ValueKey('profile-resource-$index'),
          label: 'Ресурс / размер',
          value: draft.resourceNote,
          enabled: enabled,
          onChanged: (value) => onChanged(draft.copyWith(resourceNote: value)),
        ),
        SwitchListTile(
          key: ValueKey('profile-has-pricing-$index'),
          contentPadding: EdgeInsets.zero,
          title: const Text('Ценовые метаданные'),
          value: draft.hasPricing,
          onChanged: enabled
              ? (value) => onChanged(draft.copyWith(hasPricing: value))
              : null,
        ),
        if (draft.hasPricing) ...[
          SwitchListTile(
            key: ValueKey('profile-zero-fee-$index'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Нет платы провайдеру'),
            value: draft.zeroProviderFee,
            onChanged: enabled
                ? (value) => onChanged(draft.copyWith(zeroProviderFee: value))
                : null,
          ),
          _field(
            key: ValueKey('profile-currency-$index'),
            label: 'Валюта',
            value: draft.currency,
            enabled: enabled,
            onChanged: (value) => onChanged(draft.copyWith(currency: value)),
          ),
          _field(
            key: ValueKey('profile-price-date-$index'),
            label: 'Дата тарифа (ГГГГ-ММ-ДД)',
            value: draft.effectiveDate,
            enabled: enabled,
            onChanged: (value) =>
                onChanged(draft.copyWith(effectiveDate: value)),
          ),
          _field(
            key: ValueKey('profile-price-source-$index'),
            label: 'Ссылка на тариф',
            value: draft.pricingSourceUrl,
            enabled: enabled,
            onChanged: (value) =>
                onChanged(draft.copyWith(pricingSourceUrl: value)),
          ),
          _field(
            key: ValueKey('profile-price-hit-$index'),
            label: 'Cache-hit / 1M',
            value: draft.cacheHitInputPerMillion,
            enabled: enabled,
            onChanged: (value) =>
                onChanged(draft.copyWith(cacheHitInputPerMillion: value)),
          ),
          _field(
            key: ValueKey('profile-price-miss-$index'),
            label: 'Cache-miss / 1M',
            value: draft.cacheMissInputPerMillion,
            enabled: enabled,
            onChanged: (value) =>
                onChanged(draft.copyWith(cacheMissInputPerMillion: value)),
          ),
          _field(
            key: ValueKey('profile-price-output-$index'),
            label: 'Output / 1M',
            value: draft.outputPerMillion,
            enabled: enabled,
            onChanged: (value) =>
                onChanged(draft.copyWith(outputPerMillion: value)),
          ),
        ],
      ],
    );
  }

  static Widget _field({
    required Key key,
    required String label,
    required String value,
    required bool enabled,
    required ValueChanged<String> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextFormField(
        key: key,
        initialValue: value,
        enabled: enabled,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
        onChanged: onChanged,
      ),
    );
  }

  static String _statusText(ApiKeyStatus status, ChatModelProfile profile) {
    return switch (status.source) {
      ApiKeySource.applicationOverride =>
        'Активный источник: сохранённый ключ приложения. Значение скрыто.',
      ApiKeySource.environment =>
        'Активный источник: переменная ${profile.environmentVariableName ?? 'окружения'}. Значение скрыто.',
      ApiKeySource.missing =>
        'Ключ не найден. Сохраните его здесь или задайте переменную окружения.',
      ApiKeySource.none =>
        'Аутентификация не требуется. Заголовок Authorization не отправляется.',
    };
  }
}
