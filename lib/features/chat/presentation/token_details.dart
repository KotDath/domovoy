import 'package:flutter/material.dart';

import '../../../core/llm/llm.dart';
import '../../../design_system/design_system.dart';
import '../application/chat_token_presenter.dart';

class ChatContextChip extends StatelessWidget {
  const ChatContextChip({
    required this.projection,
    required this.onPressed,
    this.model,
    super.key,
  });

  final ChatTokenProjection? projection;
  final LlmModel? model;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final tokens = context.domovoyTheme;
    final used = _usedValue(projection);
    final limit = model?.knownContextBound;
    final ratio = used != null && limit != null && limit > 0
        ? (used / limit).clamp(0.0, 1.0)
        : 0.0;
    return Semantics(
      button: true,
      label: used == null || limit == null
          ? 'Открыть сведения о контексте'
          : 'Контекст: ${(ratio * 100).toStringAsFixed(1)} процента',
      child: GestureDetector(
        key: const ValueKey('token-summary'),
        behavior: HitTestBehavior.opaque,
        onTap: projection == null ? null : onPressed,
        child: Padding(
          padding: const EdgeInsets.all(DomovoyDimensions.space3),
          child: SizedBox(
            width: DomovoyDimensions.iconSmall,
            height: DomovoyDimensions.iconSmall,
            child: CustomPaint(
              painter: _RingPainter(
                progress: ratio,
                track: tokens.border,
                fill: tokens.accent,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ChatTokenSummary extends ChatContextChip {
  const ChatTokenSummary({
    required super.projection,
    required super.onPressed,
    super.key,
  });
}

int? _usedValue(ChatTokenProjection? projection) {
  return _metric(projection, 'current-request', 'Ввод') ??
      _metric(projection, 'history', 'Всего');
}

int? _metric(ChatTokenProjection? projection, String groupKey, String label) {
  if (projection == null) return null;
  for (final group in projection.primaryGroups) {
    if (group.key != groupKey) continue;
    for (final value in group.values) {
      if (value.label != label) continue;
      if (value.state == ChatTokenValueState.unavailable) return null;
      return int.tryParse(value.display.replaceAll(RegExp(r'[^0-9]'), ''));
    }
  }
  return null;
}

String _formatTokens(int n) {
  if (n >= 1000000) {
    final value = n / 1000000;
    return '${_comma(value, value >= 10 ? 0 : 1)}M';
  }
  if (n >= 1000) {
    final value = n / 1000;
    return '${_comma(value, value >= 100 ? 0 : 1)}k';
  }
  return '$n';
}

String _comma(double value, int fraction) =>
    value.toStringAsFixed(fraction).replaceAll('.', ',');

Future<void> showChatTokenDetails({
  required BuildContext context,
  required ChatTokenProjection projection,
  LlmModel? model,
}) {
  final media = MediaQuery.of(context);
  final layout = resolveWorkspaceLayout(media.size, media.textScaler.scale(1));
  if (layout.isDesktop) {
    return showDomovoyAnchoredPopover<void>(
      context: context,
      width: DomovoyDimensions.contextPopoverWidth,
      builder: (popoverContext) => DomovoyPopoverCard(
        padding: DomovoyDimensions.panelInsets,
        child: _TokenDetailsContent(projection: projection, model: model),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: context.domovoyTheme.elevatedSurface,
    builder: (context) => Padding(
      padding: DomovoyDimensions.panelInsets,
      child: _TokenDetailsContent(projection: projection, model: model),
    ),
  );
}

class _TokenDetailsContent extends StatelessWidget {
  const _TokenDetailsContent({required this.projection, this.model});

  final ChatTokenProjection projection;
  final LlmModel? model;

  @override
  Widget build(BuildContext context) {
    final tokens = context.domovoyTheme;
    final used = _usedValue(projection);
    final limit = model?.knownContextBound;
    final ratio = used != null && limit != null && limit > 0
        ? (used / limit).clamp(0.0, 1.0)
        : null;
    final rows = <(String, int?, Color)>[
      ('Ввод', _metric(projection, 'current-request', 'Ввод'), tokens.accent),
      (
        'Рассуждение',
        _metric(projection, 'current-request', 'Рассуждение'),
        tokens.textSecondary,
      ),
      (
        'Кэш',
        _metric(projection, 'current-request', 'Чтение кэша'),
        tokens.textMuted,
      ),
    ];
    return Semantics(
      namesRoute: true,
      label: 'Сведения о контексте',
      child: Column(
        key: const ValueKey('token-details'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Контекст',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              Text(
                used == null || limit == null
                    ? '—'
                    : '${_formatTokens(used)} / ${_formatTokens(limit)}'
                          '${ratio == null ? '' : '  (${(ratio * 100).toStringAsFixed(1)}%)'}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: tokens.textMuted,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: DomovoyDimensions.space4),
          ClipRRect(
            borderRadius: BorderRadius.circular(DomovoyDimensions.radiusPill),
            child: SizedBox(
              height: 6,
              child: LinearProgressIndicator(
                value: ratio ?? 0,
                backgroundColor: tokens.border,
                color: tokens.accent,
              ),
            ),
          ),
          const SizedBox(height: DomovoyDimensions.space4),
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: DomovoyDimensions.space3),
              child: Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: row.$3,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: DomovoyDimensions.space3),
                  Expanded(
                    child: Text(
                      row.$1,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  Text(
                    row.$2 == null
                        ? '—'
                        : limit == null || limit == 0
                        ? _formatTokens(row.$2!)
                        : '${((row.$2! / limit) * 100).toStringAsFixed(1)}%',
                    key: ValueKey('token-value:current-request:${row.$1}'),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
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

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.progress,
    required this.track,
    required this.fill,
  });

  final double progress;
  final Color track;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide;
    final strokeWidth = (side * 0.18).clamp(1.5, 2.5);
    final rect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2),
      width: side - strokeWidth,
      height: side - strokeWidth,
    );
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    stroke.color = track;
    canvas.drawArc(rect, 0, 6.2832, false, stroke);
    if (progress > 0) {
      stroke.color = fill;
      canvas.drawArc(rect, -1.5708, 6.2832 * progress, false, stroke);
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.track != track ||
      oldDelegate.fill != fill;
}
