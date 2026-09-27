import 'package:flutter/material.dart';

import '../../../core/agents/ids.dart';
import '../../../core/mcp/mcp.dart';
import '../../../core/projects/ids.dart';
import '../../../design_system/design_system.dart';
import '../application/mcp_tool_access_controller.dart';
import '../application/mcp_tool_access_state.dart';

/// Opens the per-chat/project MCP permission sheet for [controller].
Future<void> showMcpToolAccessSheet({
  required BuildContext context,
  required McpToolAccessController controller,
  AgentSessionId? chatId,
  ProjectId? projectId,
}) async {
  await controller.attachScope(chatId: chatId, projectId: projectId);
  if (!context.mounted) {
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) {
      return ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: DomovoyDimensions.settingsDialogWidth + 160,
        ),
        child: Padding(
          padding: const EdgeInsets.only(top: DomovoyDimensions.space3),
          child: McpToolAccessView(controller: controller),
        ),
      );
    },
  );
}

/// Reusable, host-agnostic permission selection surface.
class McpToolAccessView extends StatelessWidget {
  const McpToolAccessView({required this.controller, super.key});

  final McpToolAccessController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => _body(context, controller.state),
    );
  }

  Widget _body(BuildContext context, McpToolAccessState state) {
    final tokens = context.domovoyTheme;
    return SingleChildScrollView(
      padding: DomovoyDimensions.pageInsets,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Инструменты MCP',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: DomovoyDimensions.space2),
          Text(
            'Разрешения выдаются по стабильным ID инструментов. '
            'Новые инструменты серверов не получают доступ автоматически.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: tokens.textSecondary),
          ),
          const SizedBox(height: DomovoyDimensions.space4),
          if (state.hasChat && state.hasProject)
            _scopeSelector(context, state)
          else if (state.scope == McpToolAccessTargetKind.project)
            Text(
              'Область: проект',
              key: const ValueKey('mcp-tool-scope-label'),
              style: Theme.of(context).textTheme.labelLarge,
            )
          else
            Text(
              'Область: чат',
              key: const ValueKey('mcp-tool-scope-label'),
              style: Theme.of(context).textTheme.labelLarge,
            ),
          if (state.error != null) ...[
            const SizedBox(height: DomovoyDimensions.space3),
            _notice(
              context,
              key: const ValueKey('mcp-tool-access-error'),
              message: state.error!,
              tone: tokens.danger,
            ),
          ],
          const SizedBox(height: DomovoyDimensions.space4),
          _summary(context, state),
          const SizedBox(height: DomovoyDimensions.space4),
          if (state.isLoading)
            const Padding(
              padding: EdgeInsets.all(DomovoyDimensions.space5),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (state.connections.isEmpty)
            Text(
              'Подключённые серверы не объявили инструментов.',
              key: const ValueKey('mcp-tool-access-empty'),
              style: Theme.of(context).textTheme.bodyMedium,
            )
          else
            for (final connection in state.connections) ...[
              _connectionCard(context, state, connection),
              const SizedBox(height: DomovoyDimensions.space4),
            ],
          if (state.missingSelectedToolIds.isNotEmpty)
            _missingTools(context, state),
        ],
      ),
    );
  }

  Widget _scopeSelector(BuildContext context, McpToolAccessState state) {
    return SegmentedButton<McpToolAccessTargetKind>(
      key: const ValueKey('mcp-tool-scope-selector'),
      segments: const <ButtonSegment<McpToolAccessTargetKind>>[
        ButtonSegment(value: McpToolAccessTargetKind.chat, label: Text('Чат')),
        ButtonSegment(
          value: McpToolAccessTargetKind.project,
          label: Text('Проект'),
        ),
      ],
      selected: <McpToolAccessTargetKind>{state.scope},
      onSelectionChanged: (selection) {
        controller.setScope(selection.first);
      },
    );
  }

  Widget _summary(BuildContext context, McpToolAccessState state) {
    return Wrap(
      spacing: DomovoyDimensions.space2,
      runSpacing: DomovoyDimensions.space2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          'Выбрано: ${state.selectedCount}',
          key: const ValueKey('mcp-tool-selected-count'),
          style: Theme.of(context).textTheme.labelLarge,
        ),
        DomovoyQuietButton(
          key: const ValueKey('mcp-tool-select-all'),
          onPressed: state.busy ? null : () => controller.selectAll(),
          child: const Text('Выбрать все'),
        ),
        DomovoyQuietButton(
          key: const ValueKey('mcp-tool-clear-all'),
          onPressed: state.busy ? null : () => controller.clearSelection(),
          child: const Text('Снять все'),
        ),
      ],
    );
  }

  Widget _connectionCard(
    BuildContext context,
    McpToolAccessState state,
    McpToolAccessConnection connection,
  ) {
    final tokens = context.domovoyTheme;
    return DomovoySurface(
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
                child: Text(
                  connection.alias,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              if (connection.unavailableReason != null)
                DomovoyStatusChip(
                  label: 'ошибка',
                  tone: DomovoyStatusTone.warning,
                ),
            ],
          ),
          const SizedBox(height: DomovoyDimensions.space2),
          Wrap(
            spacing: DomovoyDimensions.space2,
            runSpacing: DomovoyDimensions.space2,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              DomovoyStatusChip(
                label: connection.connected ? 'подключён' : 'офлайн',
                tone: connection.connected
                    ? DomovoyStatusTone.success
                    : DomovoyStatusTone.warning,
              ),
              DomovoyQuietButton(
                key: ValueKey(
                  'mcp-connection-toggle-${connection.connectionId}',
                ),
                onPressed: state.busy
                    ? null
                    : () => controller.setConnectionSelected(
                        connection.connectionId,
                        connection.selectedCount != connection.tools.length,
                      ),
                child: Text(
                  connection.selectedCount == connection.tools.length &&
                          connection.tools.isNotEmpty
                      ? 'Снять сервер'
                      : 'Выбрать сервер',
                ),
              ),
            ],
          ),
          if (connection.unavailableReason != null) ...[
            const SizedBox(height: DomovoyDimensions.space2),
            Text(
              connection.unavailableReason!,
              key: ValueKey('mcp-connection-reason-${connection.connectionId}'),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: tokens.warning),
            ),
          ],
          const SizedBox(height: DomovoyDimensions.space2),
          for (final tool in connection.tools) _toolRow(context, state, tool),
        ],
      ),
    );
  }

  Widget _toolRow(
    BuildContext context,
    McpToolAccessState state,
    McpToolAccessTool tool,
  ) {
    final tokens = context.domovoyTheme;
    final reason = tool.unavailableReason ?? tool.connectionUnavailableReason;
    return InkWell(
      key: ValueKey('mcp-tool-row-${tool.toolId}'),
      onTap: state.busy
          ? null
          : () => controller.toggleTool(tool.toolId, !tool.selected),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: DomovoyDimensions.space2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: DomovoyDimensions.minimumTarget,
              height: DomovoyDimensions.minimumTarget,
              child: Checkbox(
                key: ValueKey('mcp-tool-checkbox-${tool.toolId}'),
                value: tool.selected,
                onChanged: state.busy
                    ? null
                    : (value) =>
                          controller.toggleTool(tool.toolId, value ?? false),
              ),
            ),
            const SizedBox(width: DomovoyDimensions.space2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    tool.title ?? tool.originalName,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: DomovoyDimensions.space1),
                  Text(
                    '${tool.originalName} · ${tool.toolId}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      fontFamily: 'monospace',
                      color: tokens.textMuted,
                    ),
                  ),
                  if (reason != null) ...[
                    const SizedBox(height: DomovoyDimensions.space1),
                    Text(
                      reason,
                      key: ValueKey('mcp-tool-reason-${tool.toolId}'),
                      style: Theme.of(
                        context,
                      ).textTheme.bodySmall?.copyWith(color: tokens.warning),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _missingTools(BuildContext context, McpToolAccessState state) {
    final tokens = context.domovoyTheme;
    return DomovoySurface(
      role: DomovoySurfaceRole.surface,
      border: true,
      borderRadius: BorderRadius.circular(DomovoyDimensions.radiusMedium),
      padding: DomovoyDimensions.panelInsets,
      child: Column(
        key: const ValueKey('mcp-missing-tools'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Инструменты, которых больше нет в каталоге',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: DomovoyDimensions.space2),
          Text(
            'Разрешение сохранено, но вызов будет отклонён, пока инструмент '
            'не вернётся в каталог.',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: tokens.textSecondary),
          ),
          const SizedBox(height: DomovoyDimensions.space2),
          for (final toolId in state.missingSelectedToolIds)
            Padding(
              padding: const EdgeInsets.symmetric(
                vertical: DomovoyDimensions.space1,
              ),
              child: Text(
                toolId,
                key: ValueKey('mcp-missing-tool-$toolId'),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  fontFamily: 'monospace',
                  color: tokens.warning,
                ),
              ),
            ),
        ],
      ),
    );
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
}

/// Header button that opens the permission sheet for the visible chat/project.
class McpChatToolsButton extends StatelessWidget {
  const McpChatToolsButton({
    required this.controller,
    required this.chatId,
    required this.projectId,
    super.key,
  });

  final McpToolAccessController controller;
  final AgentSessionId? chatId;
  final ProjectId? projectId;

  @override
  Widget build(BuildContext context) {
    return DomovoyQuietButton(
      key: const ValueKey('mcp-tools-open'),
      minSize: const Size.square(DomovoyDimensions.minimumTarget),
      alignment: Alignment.center,
      tooltip: 'Инструменты MCP',
      onPressed: () => showMcpToolAccessSheet(
        context: context,
        controller: controller,
        chatId: chatId,
        projectId: projectId,
      ),
      child: const Icon(
        Icons.extension_outlined,
        size: DomovoyDimensions.iconMedium,
      ),
    );
  }
}
