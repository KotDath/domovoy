import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../domain/chat_deletion_intent.dart';

Future<bool> showDeleteChatConfirmation({
  required BuildContext context,
  required ChatDeletionIntent intent,
}) async {
  final media = MediaQuery.of(context);
  final layout = resolveWorkspaceLayout(media.size, media.textScaler.scale(1));
  final Future<bool?> pending;
  if (layout.isDesktop) {
    pending = showDialog<bool>(
      context: context,
      builder: (context) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: DomovoyDimensions.settingsDialogWidth,
          ),
          child: _DeleteChatConfirmation(intent: intent),
        ),
      ),
    );
  } else {
    pending = showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _DeleteChatConfirmation(intent: intent),
    );
  }
  return (await pending) ?? false;
}

class _DeleteChatConfirmation extends StatelessWidget {
  const _DeleteChatConfirmation({required this.intent});

  final ChatDeletionIntent intent;

  @override
  Widget build(BuildContext context) {
    final tokens = context.domovoyTheme;
    return Semantics(
      namesRoute: true,
      label: 'Подтверждение удаления чата ${intent.displayTitle}',
      child: DomovoySurface(
        key: ValueKey('delete-dialog:${intent.chatId.value}'),
        role: DomovoySurfaceRole.elevated,
        padding: DomovoyDimensions.pageInsets,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Удалить «${intent.displayTitle}»?',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: DomovoyDimensions.space3),
            Text(
              'Чат будет необратимо удалён из истории Domovoy. '
              'Созданные и прикреплённые файлы удалены не будут. '
              'Отменить удаление истории нельзя.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: DomovoyDimensions.space6),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: DomovoyDimensions.space3,
              runSpacing: DomovoyDimensions.space2,
              children: [
                TextButton(
                  key: const ValueKey('delete-cancel'),
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Отмена'),
                ),
                FilledButton.icon(
                  key: const ValueKey('delete-confirm'),
                  style: FilledButton.styleFrom(
                    backgroundColor: tokens.danger,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  ),
                  onPressed: () => Navigator.pop(context, true),
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: const Text('Удалить чат'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
