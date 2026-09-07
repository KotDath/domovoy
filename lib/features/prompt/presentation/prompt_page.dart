import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../settings/domain/api_key_credentials.dart';
import '../../settings/domain/model_settings.dart';
import '../../settings/presentation/api_key_settings_dialog.dart';
import '../../settings/presentation/reasoning_settings.dart';
import '../domain/agent.dart';
import 'prompt_controller.dart';

class PromptPage extends StatefulWidget {
  const PromptPage({
    required this.agent,
    required this.overrideStore,
    required this.apiKeyResolver,
    this.modelSettingsStore,
    this.reasoningSettings,
    this.isWeb = kIsWeb,
    super.key,
  });

  final Agent agent;
  final ApiKeyOverrideStore overrideStore;
  final ApiKeyResolver apiKeyResolver;
  final DeepSeekModelSettingsStore? modelSettingsStore;
  final ReasoningSettings? reasoningSettings;
  final bool isWeb;

  @override
  State<PromptPage> createState() => _PromptPageState();
}

class _PromptPageState extends State<PromptPage> {
  late final PromptController _prompt;
  late final ReasoningSettings _reasoning;
  bool _ownsReasoning = false;
  final _inputController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _prompt = PromptController(widget.agent)..addListener(_rebuild);
    final shared = widget.reasoningSettings;
    if (shared != null) {
      _reasoning = shared;
    } else {
      _ownsReasoning = true;
      _reasoning = ReasoningSettings(
        store:
            widget.modelSettingsStore ?? InMemoryDeepSeekModelSettingsStore(),
      );
    }
    _reasoning.addListener(_syncReasoning);
    _syncReasoning();
    unawaited(_reasoning.load());
  }

  @override
  void dispose() {
    _reasoning.removeListener(_syncReasoning);
    if (_ownsReasoning) {
      _reasoning.dispose();
    }
    _prompt
      ..removeListener(_rebuild)
      ..dispose();
    _inputController.dispose();
    super.dispose();
  }

  void _syncReasoning() {
    _prompt.setThinkingMode(
      _reasoning.reasoningEnabled
          ? ThinkingMode.enabled
          : ThinkingMode.disabled,
    );
    _rebuild();
  }

  void _rebuild() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _openSettings() async {
    await showApiKeySettingsDialog(
      context: context,
      overrideStore: widget.overrideStore,
      resolver: widget.apiKeyResolver,
      isWeb: widget.isWeb,
      modelSettingsStore: widget.modelSettingsStore,
    );
    await _reasoning.load();
  }

  @override
  Widget build(BuildContext context) {
    final state = _prompt.state;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Domovoy'),
        actions: [
          IconButton(
            key: const ValueKey('open-settings'),
            tooltip: 'Настройки API',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth >= 900;
              final input = _InputPanel(
                controller: _inputController,
                state: state,
                fillHeight: isWide,
                onChanged: _prompt.clearInputError,
                onSubmit: () => _prompt.submit(_inputController.text),
              );
              final output = _OutputPanel(
                state: state,
                height: isWide
                    ? constraints.maxHeight
                    : (constraints.maxHeight * 0.62)
                          .clamp(340.0, 620.0)
                          .toDouble(),
                onToggleReasoning: _prompt.toggleReasoning,
                onOpenSettings: _openSettings,
              );

              if (isWide) {
                return Row(
                  key: const ValueKey('wide-prompt-layout'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: input),
                    const SizedBox(width: 16),
                    Expanded(child: output),
                  ],
                );
              }

              return ListView(
                key: const ValueKey('narrow-prompt-layout'),
                children: [input, const SizedBox(height: 16), output],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _InputPanel extends StatelessWidget {
  const _InputPanel({
    required this.controller,
    required this.state,
    required this.fillHeight,
    required this.onChanged,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final PromptState state;
  final bool fillHeight;
  final VoidCallback onChanged;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final inputField = TextField(
      key: const ValueKey('prompt-input'),
      controller: controller,
      enabled: !state.isStreaming,
      keyboardType: TextInputType.multiline,
      textInputAction: TextInputAction.newline,
      minLines: fillHeight ? null : 6,
      maxLines: fillHeight ? null : 12,
      expands: fillHeight,
      decoration: InputDecoration(
        hintText: 'Например: переведи этот текст или объясни идею…',
        errorText: state.inputError,
        alignLabelWithHint: true,
        border: const OutlineInputBorder(),
      ),
      onChanged: (_) => onChanged(),
    );

    return Card(
      key: const ValueKey('prompt-panel'),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Запрос', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            if (fillHeight) Expanded(child: inputField) else inputField,
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const ValueKey('submit-prompt'),
              onPressed: state.isStreaming ? null : onSubmit,
              icon: state.isStreaming
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.arrow_upward),
              label: Text(state.isStreaming ? 'Генерация…' : 'Отправить'),
            ),
          ],
        ),
      ),
    );
  }
}

class _OutputPanel extends StatelessWidget {
  const _OutputPanel({
    required this.state,
    required this.height,
    required this.onToggleReasoning,
    required this.onOpenSettings,
  });

  final PromptState state;
  final double height;
  final VoidCallback onToggleReasoning;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Card(
        key: const ValueKey('output-panel'),
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Ответ',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  if (state.status == PromptRunStatus.completed)
                    const Icon(Icons.check_circle_outline, size: 20),
                ],
              ),
            ),
            if (state.isStreaming) const LinearProgressIndicator(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                child: _OutputContents(
                  state: state,
                  onToggleReasoning: onToggleReasoning,
                  onOpenSettings: onOpenSettings,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OutputContents extends StatelessWidget {
  const _OutputContents({
    required this.state,
    required this.onToggleReasoning,
    required this.onOpenSettings,
  });

  final PromptState state;
  final VoidCallback onToggleReasoning;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (!state.hasOutput && state.failure == null) {
      return Text(
        state.isStreaming ? 'Ожидаем первые токены…' : 'Ответ появится здесь.',
        key: const ValueKey('output-placeholder'),
        style: TextStyle(color: colorScheme.onSurfaceVariant),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (state.reasoning.isNotEmpty) ...[
          _ReasoningDisclosure(
            reasoning: state.reasoning,
            expanded: state.reasoningExpanded,
            onToggle: onToggleReasoning,
          ),
          const SizedBox(height: 16),
        ],
        if (state.answer.isNotEmpty)
          SelectableText(
            state.answer,
            key: const ValueKey('answer-text'),
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        if (state.failure case final failure?) ...[
          if (state.answer.isNotEmpty) const SizedBox(height: 16),
          Container(
            key: const ValueKey('prompt-error'),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  failure.message,
                  style: TextStyle(color: colorScheme.onErrorContainer),
                ),
                if (failure.isMissingCredential) ...[
                  const SizedBox(height: 8),
                  TextButton.icon(
                    key: const ValueKey('error-open-settings'),
                    onPressed: onOpenSettings,
                    icon: const Icon(Icons.settings_outlined),
                    label: const Text('Открыть настройки'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _ReasoningDisclosure extends StatelessWidget {
  const _ReasoningDisclosure({
    required this.reasoning,
    required this.expanded,
    required this.onToggle,
  });

  final String reasoning;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey('reasoning-section'),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: expanded,
            label: 'Ход рассуждений',
            child: InkWell(
              key: const ValueKey('reasoning-toggle'),
              borderRadius: BorderRadius.circular(12),
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.psychology_outlined,
                      size: 20,
                      color: colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Ход рассуждений',
                        style: TextStyle(color: colorScheme.onSurfaceVariant),
                      ),
                    ),
                    Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: SelectableText(
                reasoning,
                key: const ValueKey('reasoning-text'),
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }
}
