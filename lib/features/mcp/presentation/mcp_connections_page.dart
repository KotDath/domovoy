import 'package:flutter/material.dart';

import '../../../core/mcp/mcp.dart';
import '../../../design_system/design_system.dart';
import '../application/mcp_connections_controller.dart';
import '../application/mcp_connections_state.dart';
import 'mcp_connection_editor.dart';

/// Full-page MCP connection management surface for settings and B9.
class McpConnectionsPage extends StatelessWidget {
  const McpConnectionsPage({required this.controller, super.key});

  final McpConnectionsController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _content(context, controller.state),
    );
  }

  Widget _content(BuildContext context, McpConnectionsState state) {
    final tokens = context.domovoyTheme;
    final capabilities = controller.capabilities;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 760;
        return SingleChildScrollView(
          padding: compact
              ? DomovoyDimensions.compactPageInsets
              : DomovoyDimensions.pageInsets,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 780),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'MCP-подключения',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: DomovoyDimensions.space1),
                            Text(
                              'Настройки общие для устройства. '
                              'Секреты хранятся в защищённом хранилище.',
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(color: tokens.textSecondary),
                            ),
                          ],
                        ),
                      ),
                      DomovoyQuietButton(
                        key: const ValueKey('mcp-connection-add'),
                        tone: DomovoyButtonTone.accent,
                        onPressed: state.isEditorOpen
                            ? null
                            : () {
                                controller.beginCreate();
                                showMcpConnectionEditor(
                                  context: context,
                                  controller: controller,
                                );
                              },
                        child: const Text('Добавить'),
                      ),
                    ],
                  ),
                  const SizedBox(height: DomovoyDimensions.space4),
                  if (!capabilities.supportsStdio) ...[
                    _notice(
                      context,
                      key: const ValueKey('mcp-stdio-constraint-page'),
                      message: capabilities.stdioUnavailableReason,
                      tone: tokens.textMuted,
                    ),
                    const SizedBox(height: DomovoyDimensions.space3),
                  ],
                  if (state.configurationError != null) ...[
                    _notice(
                      context,
                      key: const ValueKey('mcp-connections-config-error'),
                      message: sanitizeMcpText(
                        state.configurationError!.message,
                        fallback: sanitizedMcpPersistenceMessage(),
                      ),
                      tone: tokens.danger,
                    ),
                    const SizedBox(height: DomovoyDimensions.space3),
                  ],
                  if (state.error != null) ...[
                    _notice(
                      context,
                      key: const ValueKey('mcp-connections-error'),
                      message: state.error!,
                      tone: tokens.danger,
                    ),
                    const SizedBox(height: DomovoyDimensions.space3),
                  ],
                  for (final cleanup
                      in state.secretCleanupFailures.entries) ...[
                    _secretCleanupNotice(context, cleanup.key, cleanup.value),
                    const SizedBox(height: DomovoyDimensions.space3),
                  ],
                  if (state.isLoading)
                    const Padding(
                      padding: EdgeInsets.all(DomovoyDimensions.space5),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (state.connections.isEmpty)
                    _notice(
                      context,
                      key: const ValueKey('mcp-connections-empty'),
                      message:
                          'Подключений пока нет. Добавьте сторонний сервер '
                          'или дождитесь встроенных серверов.',
                      tone: tokens.textMuted,
                    )
                  else
                    for (final entry in state.connections) ...[
                      _connectionCard(context, state, entry),
                      const SizedBox(height: DomovoyDimensions.space3),
                    ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _connectionCard(
    BuildContext context,
    McpConnectionsState state,
    McpConnectionEntry entry,
  ) {
    final tokens = context.domovoyTheme;
    final selected = state.selectedConnectionId == entry.id;
    final busy = state.busyConnectionIds.contains(entry.id);
    return DomovoySurface(
      key: ValueKey('mcp-connection-${entry.id}'),
      role: DomovoySurfaceRole.surface,
      border: true,
      borderRadius: BorderRadius.circular(DomovoyDimensions.radiusMedium),
      padding: DomovoyDimensions.panelInsets,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        entry.alias,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    if (entry.isBuiltIn) ...[
                      const SizedBox(width: DomovoyDimensions.space2),
                      DomovoyStatusChip(
                        key: ValueKey('mcp-builtin-${entry.id}'),
                        label: 'встроенный',
                      ),
                    ],
                  ],
                ),
              ),
              DomovoyStatusChip(
                key: ValueKey('mcp-status-${entry.id}'),
                label: _phaseLabel(entry, busy),
                tone: _phaseTone(entry),
              ),
              const SizedBox(width: DomovoyDimensions.space2),
              Switch(
                key: ValueKey('mcp-enabled-${entry.id}'),
                value: entry.enabled,
                onChanged: busy
                    ? null
                    : (value) => controller.setEnabled(entry.id, value),
              ),
            ],
          ),
          const SizedBox(height: DomovoyDimensions.space1),
          Text(
            '${entry.id} · ${entry.transportLabel} · '
            'инструментов: ${entry.toolCount}'
            '${entry.processId == null ? '' : ' · PID ${entry.processId}'}',
            key: ValueKey('mcp-meta-${entry.id}'),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontFamily: 'monospace',
              color: tokens.textMuted,
            ),
          ),
          if (entry.handshake != null) ...[
            const SizedBox(height: DomovoyDimensions.space1),
            Text(
              '${entry.handshake!.serverName} '
              '${entry.handshake!.serverVersion} · протокол '
              '${entry.handshake!.protocolVersion}',
              key: ValueKey('mcp-handshake-${entry.id}'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (entry.lastError != null) ...[
            const SizedBox(height: DomovoyDimensions.space2),
            Text(
              entry.lastError!,
              key: ValueKey('mcp-connection-error-${entry.id}'),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: tokens.danger),
            ),
          ],
          const SizedBox(height: DomovoyDimensions.space2),
          Wrap(
            spacing: DomovoyDimensions.space2,
            runSpacing: DomovoyDimensions.space2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DomovoyQuietButton(
                key: ValueKey('mcp-check-${entry.id}'),
                onPressed: busy
                    ? null
                    : () => controller.checkConnection(entry.id),
                child: const Text('Проверить'),
              ),
              DomovoyQuietButton(
                key: ValueKey('mcp-refresh-${entry.id}'),
                onPressed: busy
                    ? null
                    : () => controller.refreshTools(entry.id),
                child: const Text('Обновить каталог'),
              ),
              DomovoyQuietButton(
                key: ValueKey('mcp-tools-${entry.id}'),
                tone: selected
                    ? DomovoyButtonTone.selected
                    : DomovoyButtonTone.quiet,
                onPressed: () =>
                    controller.selectConnection(selected ? null : entry.id),
                child: const Text('Инструменты'),
              ),
              if (entry.canEdit)
                DomovoyQuietButton(
                  key: ValueKey('mcp-edit-${entry.id}'),
                  onPressed: busy
                      ? null
                      : () async {
                          if (await controller.beginEdit(entry.id) &&
                              context.mounted) {
                            showMcpConnectionEditor(
                              context: context,
                              controller: controller,
                            );
                          }
                        },
                  child: const Text('Изменить'),
                ),
              if (entry.canEdit)
                DomovoyQuietButton(
                  key: ValueKey('mcp-remove-${entry.id}'),
                  onPressed: busy ? null : () => _confirmRemove(context, entry),
                  child: Text(
                    'Удалить',
                    style: TextStyle(color: tokens.danger),
                  ),
                ),
            ],
          ),
          if (selected) ...[
            const SizedBox(height: DomovoyDimensions.space3),
            _toolList(context, entry),
          ],
        ],
      ),
    );
  }

  Widget _toolList(BuildContext context, McpConnectionEntry entry) {
    final tokens = context.domovoyTheme;
    if (entry.routes.isEmpty) {
      return Text(
        'Сервер не объявил инструментов.',
        key: ValueKey('mcp-tool-list-${entry.id}'),
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    return Column(
      key: ValueKey('mcp-tool-list-${entry.id}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Полный каталог (${entry.routes.length})',
          style: Theme.of(context).textTheme.labelLarge,
        ),
        for (final route in entry.routes)
          Padding(
            padding: const EdgeInsets.only(top: DomovoyDimensions.space1),
            child: Text(
              '${route.originalToolName} → ${route.modelToolName.value}',
              key: ValueKey('mcp-tool-${entry.id}-${route.originalToolName}'),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontFamily: 'monospace',
                color: tokens.textSecondary,
              ),
            ),
          ),
      ],
    );
  }

  String _phaseLabel(McpConnectionEntry entry, bool busy) {
    if (busy) {
      return 'работа…';
    }
    if (!entry.enabled) {
      return 'отключено';
    }
    return switch (entry.status?.phase) {
      null => 'не запущено',
      McpConnectionPhase.disabled => 'отключено',
      McpConnectionPhase.stopped => 'остановлено',
      McpConnectionPhase.connecting => 'подключение…',
      McpConnectionPhase.ready => 'готово',
      McpConnectionPhase.failed => 'ошибка',
    };
  }

  DomovoyStatusTone _phaseTone(McpConnectionEntry entry) {
    if (!entry.enabled) {
      return DomovoyStatusTone.neutral;
    }
    return switch (entry.status?.phase) {
      McpConnectionPhase.ready => DomovoyStatusTone.success,
      McpConnectionPhase.failed => DomovoyStatusTone.danger,
      McpConnectionPhase.connecting => DomovoyStatusTone.warning,
      _ => DomovoyStatusTone.neutral,
    };
  }

  Future<void> _confirmRemove(
    BuildContext context,
    McpConnectionEntry entry,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Удалить подключение?'),
        content: Text(
          'Подключение «${entry.alias}» и сохранённые секреты будут удалены.',
        ),
        actions: [
          DomovoyQuietButton(
            key: const ValueKey('mcp-remove-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Отмена'),
          ),
          DomovoyQuietButton(
            key: const ValueKey('mcp-remove-confirm'),
            tone: DomovoyButtonTone.accent,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await controller.removeConnection(entry.id);
    }
  }

  Widget _notice(
    BuildContext context, {
    required Key key,
    required String message,
    required Color tone,
  }) {
    return Container(
      key: key,
      padding: DomovoyDimensions.controlInsets,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(DomovoyDimensions.radiusControl),
        border: Border.all(color: tone),
      ),
      child: Text(
        message,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: tone),
      ),
    );
  }

  Widget _secretCleanupNotice(
    BuildContext context,
    String connectionId,
    int count,
  ) {
    final tokens = context.domovoyTheme;
    return Container(
      key: ValueKey('mcp-secret-cleanup-$connectionId'),
      padding: DomovoyDimensions.controlInsets,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(DomovoyDimensions.radiusControl),
        border: Border.all(color: tokens.danger),
      ),
      child: Wrap(
        spacing: DomovoyDimensions.space2,
        runSpacing: DomovoyDimensions.space2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            'Секреты подключения «$connectionId» не удалены '
            '(осталось: $count). Повторите очистку.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: tokens.danger),
          ),
          DomovoyQuietButton(
            key: ValueKey('mcp-secret-cleanup-retry-$connectionId'),
            onPressed: () => controller.retrySecretCleanup(connectionId),
            child: const Text('Повторить'),
          ),
        ],
      ),
    );
  }
}
