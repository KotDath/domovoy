import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../application/mcp_connections_controller.dart';
import '../application/mcp_connections_state.dart';
import '../domain/connection_draft.dart';

/// Opens the create/edit editor for the draft already prepared on
/// [controller] (see [McpConnectionsController.beginCreate] and
/// `beginEdit`).
Future<void> showMcpConnectionEditor({
  required BuildContext context,
  required McpConnectionsController controller,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) =>
        McpConnectionEditorDialog(controller: controller),
  );
}

class McpConnectionEditorDialog extends StatefulWidget {
  const McpConnectionEditorDialog({required this.controller, super.key});

  final McpConnectionsController controller;

  @override
  State<McpConnectionEditorDialog> createState() =>
      _McpConnectionEditorDialogState();
}

class _McpConnectionEditorDialogState extends State<McpConnectionEditorDialog> {
  final _alias = TextEditingController();
  final _connectionId = TextEditingController();
  final _url = TextEditingController();
  final _token = TextEditingController();
  final _command = TextEditingController();
  final _args = TextEditingController();
  final _workingDirectory = TextEditingController();
  final List<_EnvironmentRowSeed> _environmentRows = <_EnvironmentRowSeed>[];
  final List<_EnvironmentRowSeed> _secretRows = <_EnvironmentRowSeed>[];
  var _nextRowId = 0;
  var _initialized = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    final draft = widget.controller.state.draft;
    if (draft != null) {
      _initializeFromDraft(draft);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _alias.dispose();
    _connectionId.dispose();
    _url.dispose();
    _token.dispose();
    _command.dispose();
    _args.dispose();
    _workingDirectory.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    final draft = widget.controller.state.draft;
    if (draft == null) {
      if (mounted) {
        Navigator.of(context).maybePop();
      }
      return;
    }
    if (!_initialized) {
      _initializeFromDraft(draft);
    }
    if (mounted) {
      setState(() {});
    }
  }

  void _initializeFromDraft(McpConnectionDraft draft) {
    _initialized = true;
    _alias.text = draft.alias;
    _connectionId.text = draft.connectionId;
    _url.text = draft.url;
    _command.text = draft.command;
    _args.text = draft.args.join('\n');
    _workingDirectory.text = draft.workingDirectory;
    for (final entry in draft.environment.entries) {
      _environmentRows.add(
        _EnvironmentRowSeed(
          id: _nextRowId++,
          name: entry.key,
          value: entry.value,
        ),
      );
    }
    for (final name in draft.secretEnvironmentStored) {
      _secretRows.add(
        _EnvironmentRowSeed(id: _nextRowId++, name: name, stored: true),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.controller.state;
    final draft = state.draft;
    if (draft == null) {
      return const SizedBox.shrink();
    }
    final capabilities = widget.controller.capabilities;
    final tokens = context.domovoyTheme;
    return PopScope(
      canPop: !state.saving,
      child: AlertDialog(
        key: const ValueKey('mcp-connection-editor'),
        title: Text(
          draft.isEditing ? 'Изменить подключение' : 'Новое MCP-подключение',
        ),
        content: SizedBox(
          width: DomovoyDimensions.settingsDialogWidth,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  key: const ValueKey('mcp-editor-alias'),
                  controller: _alias,
                  enabled: !state.saving,
                  decoration: const InputDecoration(
                    labelText: 'Название',
                    hintText: 'Мой сервер',
                  ),
                  onChanged: (value) => widget.controller.updateDraft(
                    (draft) => draft.copyWith(alias: value),
                  ),
                ),
                const SizedBox(height: DomovoyDimensions.space3),
                TextField(
                  key: const ValueKey('mcp-editor-id'),
                  controller: _connectionId,
                  enabled: !state.saving && !draft.isEditing,
                  decoration: const InputDecoration(
                    labelText: 'ID подключения',
                    helperText: 'Латиница, цифры, «.», «-», «_»',
                  ),
                  onChanged: (value) => widget.controller.updateDraft(
                    (draft) => draft.copyWith(connectionId: value),
                  ),
                ),
                const SizedBox(height: DomovoyDimensions.space4),
                SegmentedButton<McpConnectionTransportChoice>(
                  key: const ValueKey('mcp-editor-transport'),
                  segments: <ButtonSegment<McpConnectionTransportChoice>>[
                    ButtonSegment(
                      value: McpConnectionTransportChoice.streamableHttp,
                      label: const Text('Streamable HTTPS'),
                      enabled: capabilities.supportsRemoteHttp && !state.saving,
                    ),
                    ButtonSegment(
                      value: McpConnectionTransportChoice.stdio,
                      label: const Text('stdio'),
                      enabled: capabilities.supportsStdio && !state.saving,
                    ),
                  ],
                  selected: <McpConnectionTransportChoice>{draft.transport},
                  onSelectionChanged: state.saving
                      ? null
                      : (selection) => widget.controller.updateDraft(
                          (draft) => draft.copyWith(transport: selection.first),
                        ),
                ),
                if (!capabilities.supportsStdio &&
                    draft.transport != McpConnectionTransportChoice.stdio) ...[
                  const SizedBox(height: DomovoyDimensions.space2),
                  Text(
                    capabilities.stdioUnavailableReason,
                    key: const ValueKey('mcp-editor-stdio-constraint'),
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: tokens.textMuted),
                  ),
                ],
                if (!capabilities.supportsRemoteHttp) ...[
                  const SizedBox(height: DomovoyDimensions.space2),
                  Text(
                    capabilities.remoteHttpUnavailableReason,
                    key: const ValueKey('mcp-editor-http-constraint'),
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: tokens.textMuted),
                  ),
                ],
                const SizedBox(height: DomovoyDimensions.space4),
                if (draft.transport ==
                    McpConnectionTransportChoice.streamableHttp)
                  ..._httpFields(context, state, draft)
                else
                  ..._stdioFields(context, state, draft),
                const SizedBox(height: DomovoyDimensions.space4),
                Row(
                  children: [
                    DomovoyQuietButton(
                      key: const ValueKey('mcp-editor-check'),
                      onPressed: state.saving || state.isProbing
                          ? null
                          : widget.controller.checkDraft,
                      child: Text(state.isProbing ? 'Проверка…' : 'Проверить'),
                    ),
                    const SizedBox(width: DomovoyDimensions.space3),
                    if (state.isProbing)
                      const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
                const SizedBox(height: DomovoyDimensions.space2),
                _probeResult(context, state),
                if (state.editorError != null) ...[
                  const SizedBox(height: DomovoyDimensions.space3),
                  Text(
                    state.editorError!,
                    key: const ValueKey('mcp-editor-error'),
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: tokens.danger),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          DomovoyQuietButton(
            key: const ValueKey('mcp-editor-cancel'),
            onPressed: state.saving ? null : widget.controller.closeEditor,
            child: const Text('Отмена'),
          ),
          DomovoyQuietButton(
            key: const ValueKey('mcp-editor-save'),
            tone: DomovoyButtonTone.accent,
            onPressed: state.saving ? null : widget.controller.saveDraft,
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
  }

  List<Widget> _httpFields(
    BuildContext context,
    McpConnectionsState state,
    McpConnectionDraft draft,
  ) {
    return <Widget>[
      TextField(
        key: const ValueKey('mcp-editor-url'),
        controller: _url,
        enabled: !state.saving,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(
          labelText: 'URL',
          hintText: 'https://example.com/mcp',
        ),
        onChanged: (value) => widget.controller.updateDraft(
          (draft) => draft.copyWith(url: value),
        ),
      ),
      const SizedBox(height: DomovoyDimensions.space3),
      TextField(
        key: const ValueKey('mcp-editor-token'),
        controller: _token,
        enabled: !state.saving && !draft.removeBearerToken,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: 'Bearer-токен (необязательно)',
          helperText: draft.bearerTokenStored
              ? 'Токен уже сохранён в защищённом хранилище.'
              : 'Значение сохраняется только в защищённое хранилище.',
        ),
        onChanged: (value) => widget.controller.updateDraft(
          (draft) => draft.copyWith(bearerToken: value),
        ),
      ),
      if (draft.bearerTokenStored) ...[
        const SizedBox(height: DomovoyDimensions.space2),
        Row(
          children: [
            Checkbox(
              key: const ValueKey('mcp-editor-token-remove'),
              value: draft.removeBearerToken,
              onChanged: state.saving
                  ? null
                  : (value) => widget.controller.updateDraft(
                      (draft) =>
                          draft.copyWith(removeBearerToken: value ?? false),
                    ),
            ),
            const SizedBox(width: DomovoyDimensions.space2),
            Expanded(
              child: Text(
                'Удалить сохранённый токен',
                key: const ValueKey('mcp-editor-token-stored'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ],
    ];
  }

  List<Widget> _stdioFields(
    BuildContext context,
    McpConnectionsState state,
    McpConnectionDraft draft,
  ) {
    final tokens = context.domovoyTheme;
    return <Widget>[
      TextField(
        key: const ValueKey('mcp-editor-command'),
        controller: _command,
        enabled: !state.saving,
        decoration: const InputDecoration(
          labelText: 'Команда',
          hintText: 'npx',
        ),
        onChanged: (value) => widget.controller.updateDraft(
          (draft) => draft.copyWith(command: value),
        ),
      ),
      const SizedBox(height: DomovoyDimensions.space3),
      TextField(
        key: const ValueKey('mcp-editor-args'),
        controller: _args,
        enabled: !state.saving,
        maxLines: 4,
        minLines: 2,
        decoration: const InputDecoration(
          labelText: 'Аргументы (по одному на строку)',
          helperText: 'Передаются массивом, без shell-подстановки.',
        ),
        onChanged: widget.controller.setDraftArgsText,
      ),
      const SizedBox(height: DomovoyDimensions.space3),
      TextField(
        key: const ValueKey('mcp-editor-workdir'),
        controller: _workingDirectory,
        enabled: !state.saving,
        decoration: const InputDecoration(
          labelText: 'Рабочий каталог (необязательно)',
        ),
        onChanged: (value) => widget.controller.updateDraft(
          (draft) => draft.copyWith(workingDirectory: value),
        ),
      ),
      const SizedBox(height: DomovoyDimensions.space4),
      _environmentSection(context, state, secret: false),
      const SizedBox(height: DomovoyDimensions.space3),
      _environmentSection(context, state, secret: true),
      if (draft.environment.isNotEmpty) ...[
        const SizedBox(height: DomovoyDimensions.space2),
        Text(
          'Значения из открытых переменных попадают в конфигурацию JSONL.',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: tokens.textMuted),
        ),
      ],
    ];
  }

  Widget _environmentSection(
    BuildContext context,
    McpConnectionsState state, {
    required bool secret,
  }) {
    final tokens = context.domovoyTheme;
    final rows = secret ? _secretRows : _environmentRows;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                secret
                    ? 'Секретные переменные окружения'
                    : 'Переменные окружения',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
            DomovoyQuietButton(
              key: ValueKey(
                secret ? 'mcp-editor-secret-add' : 'mcp-editor-env-add',
              ),
              onPressed: state.saving
                  ? null
                  : () => setState(() {
                      rows.add(_EnvironmentRowSeed(id: _nextRowId++));
                    }),
              child: const Text('Добавить'),
            ),
          ],
        ),
        if (secret)
          Text(
            'Значения секретных переменных хранятся только в защищённом '
            'хранилище и не показываются после сохранения.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: tokens.textMuted),
          ),
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.only(top: DomovoyDimensions.space2),
            child: _EnvironmentRow(
              key: ValueKey(
                '${secret ? 'mcp-editor-secret' : 'mcp-editor-env'}-${row.id}',
              ),
              rowKey:
                  '${secret ? 'mcp-editor-secret' : 'mcp-editor-env'}-'
                  '${row.id}',
              seed: row,
              secret: secret,
              enabled: !state.saving,
              onChanged: (previousName, name, value) {
                final trimmed = name.trim();
                row.name = trimmed;
                _onRowChanged(
                  secret: secret,
                  previousName: previousName,
                  name: name,
                  value: value,
                );
              },
              onRemoved: () => _removeRow(secret: secret, seed: row),
            ),
          ),
      ],
    );
  }

  void _onRowChanged({
    required bool secret,
    required String? previousName,
    required String name,
    required String value,
  }) {
    if (previousName != null &&
        previousName.isNotEmpty &&
        previousName != name) {
      if (secret) {
        widget.controller.removeSecretEnvironmentVariable(previousName);
      } else {
        widget.controller.removeEnvironmentVariable(previousName);
      }
    }
    if (name.trim().isEmpty) {
      return;
    }
    if (secret) {
      widget.controller.setSecretEnvironmentVariable(name, value);
    } else {
      widget.controller.setEnvironmentVariable(name, value);
    }
  }

  void _removeRow({required bool secret, required _EnvironmentRowSeed seed}) {
    setState(() {
      (secret ? _secretRows : _environmentRows).remove(seed);
    });
    if (seed.name.isEmpty) {
      return;
    }
    if (secret) {
      widget.controller.removeSecretEnvironmentVariable(seed.name);
    } else {
      widget.controller.removeEnvironmentVariable(seed.name);
    }
  }

  Widget _probeResult(BuildContext context, McpConnectionsState state) {
    final tokens = context.domovoyTheme;
    if (state.probeStatus == McpProbeStatus.idle) {
      return const SizedBox.shrink();
    }
    if (state.probeStatus == McpProbeStatus.running) {
      return Text(
        'Выполняется handshake и полный tools/list…',
        key: const ValueKey('mcp-editor-probe-status'),
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    final result = state.probeResult;
    if (result == null) {
      return const SizedBox.shrink();
    }
    if (!result.ok) {
      return Text(
        'Ошибка проверки: ${result.error ?? 'не удалось подключиться'}',
        key: const ValueKey('mcp-editor-probe-error'),
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: tokens.danger),
      );
    }
    final handshake = result.handshake;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Сервер: ${handshake?.serverName ?? '—'} '
          '${handshake?.serverVersion ?? ''} · '
          'протокол ${handshake?.protocolVersion ?? '—'}',
          key: const ValueKey('mcp-editor-probe-handshake'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: DomovoyDimensions.space2),
        Text(
          'Инструменты (${result.tools.length}): '
          '${result.tools.map((tool) => tool.originalName).join(', ')}',
          key: const ValueKey('mcp-editor-probe-tools'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

final class _EnvironmentRowSeed {
  _EnvironmentRowSeed({
    required this.id,
    this.name = '',
    this.value = '',
    this.stored = false,
  });

  final int id;
  String name;
  String value;
  final bool stored;
}

class _EnvironmentRow extends StatefulWidget {
  const _EnvironmentRow({
    required this.rowKey,
    required this.seed,
    required this.secret,
    required this.enabled,
    required this.onChanged,
    required this.onRemoved,
    super.key,
  });

  final String rowKey;
  final _EnvironmentRowSeed seed;
  final bool secret;
  final bool enabled;
  final void Function(String? previousName, String name, String value)
  onChanged;
  final VoidCallback onRemoved;

  @override
  State<_EnvironmentRow> createState() => _EnvironmentRowState();
}

class _EnvironmentRowState extends State<_EnvironmentRow> {
  late final TextEditingController _name = TextEditingController(
    text: widget.seed.name,
  );
  late final TextEditingController _value = TextEditingController(
    text: widget.seed.value,
  );
  String? _lastName;

  @override
  void initState() {
    super.initState();
    final seedName = widget.seed.name.trim();
    _lastName = seedName.isEmpty ? null : seedName;
  }

  @override
  void dispose() {
    _name.dispose();
    _value.dispose();
    super.dispose();
  }

  void _notify() {
    widget.onChanged(_lastName, _name.text, _value.text);
    _lastName = _name.text;
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: TextField(
            key: ValueKey('${widget.rowKey}-name'),
            controller: _name,
            enabled: widget.enabled && !widget.seed.stored,
            decoration: const InputDecoration(labelText: 'Имя'),
            onChanged: (_) => _notify(),
          ),
        ),
        const SizedBox(width: DomovoyDimensions.space2),
        Expanded(
          child: TextField(
            key: ValueKey('${widget.rowKey}-value'),
            controller: _value,
            enabled: widget.enabled,
            obscureText: widget.secret,
            decoration: InputDecoration(
              labelText: 'Значение',
              hintText: widget.seed.stored ? 'сохранено' : null,
              helperText: widget.seed.stored && widget.secret
                  ? 'Сохранено (не отображается)'
                  : null,
            ),
            onChanged: (_) => _notify(),
          ),
        ),
        DomovoyQuietButton(
          key: ValueKey('${widget.rowKey}-remove'),
          minSize: const Size.square(DomovoyDimensions.minimumTarget),
          alignment: Alignment.center,
          onPressed: widget.enabled ? widget.onRemoved : null,
          tooltip: 'Удалить',
          child: const Icon(
            Icons.close_rounded,
            size: DomovoyDimensions.iconSmall,
          ),
        ),
      ],
    );
  }
}
