import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/agents/agents.dart';
import '../../../core/llm/llm.dart';
import '../../../design_system/design_system.dart';
import '../../../infrastructure/llm/discovery/provider_model_catalog.dart';
import '../application/chat_token_presenter.dart';
import '../application/chat_workspace_state.dart';
import 'model_selector.dart';
import 'reasoning_selector.dart';
import 'token_details.dart';

class ChatComposer extends StatefulWidget {
  const ChatComposer({
    required this.providerGroups,
    required this.selection,
    required this.onSend,
    required this.onStop,
    required this.onSelectionChanged,
    required this.running,
    required this.enabled,
    this.initialDraft,
    this.providerCatalog,
    this.onRefreshModels,
    this.tokenProjection,
    this.onOpenTokens,
    this.onOpenProviders,
    this.selectedModel,
    super.key,
  });

  final List<LlmProviderGroup> providerGroups;
  final AgentSessionSelection selection;
  final Future<ChatCommandResult> Function(String draft) onSend;
  final Future<ChatCommandResult> Function() onStop;
  final Future<ChatCommandResult> Function(AgentSessionSelection selection)
  onSelectionChanged;
  final bool running;
  final bool enabled;
  final String? initialDraft;
  final ProviderCatalogSnapshot? providerCatalog;
  final Future<ProviderCatalogSnapshot?> Function()? onRefreshModels;
  final ChatTokenProjection? tokenProjection;
  final VoidCallback? onOpenTokens;
  final VoidCallback? onOpenProviders;
  final LlmModel? selectedModel;

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class ChatUnavailableComposer extends StatelessWidget {
  const ChatUnavailableComposer({super.key});

  @override
  Widget build(BuildContext context) => Semantics(
    textField: true,
    enabled: false,
    label: 'Создайте или выберите чат для отправки сообщения',
    child: DomovoySurface(
      key: const ValueKey('chat-composer'),
      role: DomovoySurfaceRole.elevated,
      border: true,
      borderRadius: BorderRadius.circular(DomovoyDimensions.radiusComposer),
      padding: DomovoyDimensions.composerInsets,
      child: Text(
        'Создайте или выберите чат, чтобы написать сообщение.',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: context.domovoyTheme.textSecondary,
        ),
      ),
    ),
  );
}

class _ChatComposerState extends State<ChatComposer> {
  late final TextEditingController _textController;
  final _focusNode = FocusNode(debugLabel: 'chat-composer');
  var _submitting = false;
  var _stopping = false;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.initialDraft);
  }

  @override
  void dispose() {
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.domovoyTheme;
    final model =
        widget.selectedModel ??
        modelForSelection(widget.providerGroups, widget.selection);
    final canEdit = widget.enabled && !widget.running && !_submitting;
    return Semantics(
      textField: true,
      enabled: canEdit,
      label: 'Сообщение для текущего чата',
      child: DomovoySurface(
        key: const ValueKey('chat-composer'),
        role: DomovoySurfaceRole.elevated,
        border: true,
        borderRadius: BorderRadius.circular(DomovoyDimensions.radiusComposer),
        padding: DomovoyDimensions.composerInsets,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CallbackShortcuts(
              bindings: <ShortcutActivator, VoidCallback>{
                const SingleActivator(LogicalKeyboardKey.enter): _submit,
                const SingleActivator(LogicalKeyboardKey.enter, shift: true):
                    _insertNewline,
              },
              child: TextField(
                key: const ValueKey('chat-composer-field'),
                controller: _textController,
                focusNode: _focusNode,
                enabled: canEdit,
                minLines: 2,
                maxLines: 4,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                decoration: const InputDecoration(
                  hintText: 'Что обдумаем вместе?',
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(height: DomovoyDimensions.space3),
            Row(
              children: [
                DomovoyQuietButton(
                  key: const ValueKey('composer-context-plus'),
                  minSize: const Size.square(DomovoyDimensions.toolTarget),
                  onPressed: _openTokens,
                  tooltip: 'Показать контекст',
                  child: const Text('＋'),
                ),
                const Spacer(),
                ChatContextChip(
                  projection: widget.tokenProjection,
                  model: model,
                  onPressed: _openTokens,
                ),
                ChatModelSelector(
                  groups: widget.providerGroups,
                  selection: widget.selection,
                  enabled: canEdit,
                  onSelected: _changeSelection,
                  catalog: widget.providerCatalog,
                  onRefreshModels: widget.onRefreshModels,
                  onManageProviders: widget.onOpenProviders,
                ),
                if (model != null)
                  ChatReasoningSelector(
                    model: model,
                    selection: widget.selection,
                    enabled: canEdit,
                    onSelected: (choice) => _changeSelection(
                      AgentSessionSelection(
                        model: widget.selection.model,
                        reasoningMode: choice.mode,
                        reasoningEffort: choice.effort,
                      ),
                    ),
                  ),
                Semantics(
                  button: true,
                  enabled: widget.running ? !_stopping : _canSubmit,
                  label: widget.running
                      ? 'Остановить ответ'
                      : 'Отправить сообщение',
                  child: DomovoyQuietButton(
                    key: ValueKey(widget.running ? 'chat-stop' : 'chat-send'),
                    minSize: const Size.square(DomovoyDimensions.toolTarget),
                    tone: DomovoyButtonTone.accent,
                    onPressed: widget.running
                        ? _stopping
                              ? null
                              : _stop
                        : _canSubmit
                        ? _submit
                        : null,
                    tooltip: widget.running
                        ? 'Остановить ответ'
                        : 'Отправить сообщение',
                    child: widget.running
                        ? Icon(
                            Icons.stop_rounded,
                            size: DomovoyDimensions.iconSmall,
                            color: tokens.accent,
                          )
                        : DomovoyIcon(
                            DomovoyIconKind.send,
                            color: tokens.accent,
                          ),
                  ),
                ),
              ],
            ),
            if (model == null)
              Padding(
                padding: const EdgeInsets.only(top: DomovoyDimensions.space2),
                child: Text(
                  'Модель больше недоступна. Выберите замену.',
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: tokens.danger),
                ),
              ),
          ],
        ),
      ),
    );
  }

  bool get _canSubmit =>
      widget.enabled &&
      !widget.running &&
      !_submitting &&
      modelForSelection(widget.providerGroups, widget.selection) != null &&
      _textController.text.trim().isNotEmpty;

  bool get _isComposing {
    final composing = _textController.value.composing;
    return composing.isValid && !composing.isCollapsed;
  }

  void _insertNewline() {
    if (!widget.enabled || widget.running || _submitting || _isComposing) {
      return;
    }
    final value = _textController.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final nextText = value.text.replaceRange(
      selection.start,
      selection.end,
      '\n',
    );
    _textController.value = value.copyWith(
      text: nextText,
      selection: TextSelection.collapsed(offset: selection.start + 1),
      composing: TextRange.empty,
    );
    setState(() {});
  }

  void _submit() {
    if (_isComposing || !_canSubmit) return;
    final draft = _textController.text;
    setState(() => _submitting = true);
    unawaited(_performSubmit(draft));
  }

  Future<void> _performSubmit(String draft) async {
    final result = await widget.onSend(draft);
    if (!mounted) return;
    if (result.status == ChatCommandStatus.succeeded &&
        _textController.text == draft) {
      _textController.clear();
    }
    setState(() => _submitting = false);
    _focusNode.requestFocus();
  }

  void _stop() => unawaited(_performStop());

  Future<void> _performStop() async {
    if (_stopping) return;
    setState(() => _stopping = true);
    await widget.onStop();
    if (!mounted) return;
    setState(() => _stopping = false);
    _focusNode.requestFocus();
  }

  void _changeSelection(AgentSessionSelection selection) {
    if (!widget.enabled || widget.running || _submitting) return;
    unawaited(widget.onSelectionChanged(selection));
  }

  void _openTokens() {
    final projection = widget.tokenProjection;
    if (projection == null) return;
    unawaited(
      showChatTokenDetails(
        context: context,
        projection: projection,
        model:
            widget.selectedModel ??
            modelForSelection(widget.providerGroups, widget.selection),
      ),
    );
  }
}
