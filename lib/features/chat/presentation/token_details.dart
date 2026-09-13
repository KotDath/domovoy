import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../application/chat_token_presenter.dart';

class ChatTokenSummary extends StatelessWidget {
  const ChatTokenSummary({
    required this.projection,
    required this.onPressed,
    this.compact = false,
    super.key,
  });

  final ChatTokenProjection? projection;
  final VoidCallback? onPressed;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final label = projection?.summaryLabel ?? 'Токены —';
    return Semantics(
      button: true,
      label: 'Открыть сведения о токенах. $label',
      child: TextButton.icon(
        key: const ValueKey('token-summary'),
        onPressed: projection == null ? null : onPressed,
        icon: const Icon(Icons.data_usage_rounded),
        label: compact
            ? const SizedBox.shrink()
            : Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

Future<void> showChatTokenDetails({
  required BuildContext context,
  required ChatTokenProjection projection,
}) {
  final media = MediaQuery.of(context);
  final layout = resolveWorkspaceLayout(media.size, media.textScaler.scale(1));
  if (layout.isDesktop) {
    return showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: DomovoyDimensions.settingsDialogWidth,
          ),
          child: _TokenDetailsContent(projection: projection),
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => _TokenDetailsContent(projection: projection),
  );
}

class _TokenDetailsContent extends StatelessWidget {
  const _TokenDetailsContent({required this.projection});

  final ChatTokenProjection projection;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      namesRoute: true,
      label: 'Сведения о токенах',
      child: DomovoySurface(
        key: const ValueKey('token-details'),
        role: DomovoySurfaceRole.elevated,
        child: SingleChildScrollView(
          padding: DomovoyDimensions.pageInsets,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Токены и контекст',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  DomovoyIconAction(
                    key: const ValueKey('token-details-close'),
                    icon: Icons.close_rounded,
                    label: 'Закрыть сведения о токенах',
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: DomovoyDimensions.space6),
              for (final group in projection.primaryGroups) ...[
                _TokenGroupCard(group: group),
                const SizedBox(height: DomovoyDimensions.space4),
              ],
              Text(
                'Дополнительные срезы',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: DomovoyDimensions.space3),
              for (final group in projection.supplementaryGroups) ...[
                _TokenGroupCard(group: group),
                const SizedBox(height: DomovoyDimensions.space4),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _TokenGroupCard extends StatelessWidget {
  const _TokenGroupCard({required this.group});

  final ChatTokenGroup group;

  @override
  Widget build(BuildContext context) {
    final tokens = context.domovoyTheme;
    return DomovoySurface(
      key: ValueKey('token-group:${group.key}'),
      role: DomovoySurfaceRole.surface,
      border: true,
      borderRadius: BorderRadius.circular(DomovoyDimensions.radiusMedium),
      padding: DomovoyDimensions.panelInsets,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(group.title, style: Theme.of(context).textTheme.titleSmall),
          if (group.modelLabel != null)
            Text(
              group.modelLabel!,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: tokens.textSecondary),
            ),
          if (group.correlationLabel != null)
            Text(
              group.correlationLabel!,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: tokens.textSecondary),
            ),
          if (group.note != null) ...[
            const SizedBox(height: DomovoyDimensions.space2),
            Text(group.note!, style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: DomovoyDimensions.space3),
          for (final value in group.values)
            Padding(
              padding: const EdgeInsets.only(bottom: DomovoyDimensions.space2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: Text(value.label)),
                  const SizedBox(width: DomovoyDimensions.space3),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          value.display,
                          key: ValueKey(
                            'token-value:${group.key}:${value.label}',
                          ),
                        ),
                        if (value.provenanceLabel != null)
                          Text(
                            value.provenanceLabel!,
                            textAlign: TextAlign.end,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        if (value.explanation != null)
                          Text(
                            value.explanation!,
                            textAlign: TextAlign.end,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
