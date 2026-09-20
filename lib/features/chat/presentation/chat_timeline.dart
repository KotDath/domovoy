import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';
import '../application/chat_timeline_projector.dart';
import 'timeline_parts.dart';

class ChatTimeline extends StatefulWidget {
  const ChatTimeline({
    required this.projection,
    this.announcement,
    this.onOpenSettings,
    this.durationLabel,
    super.key,
  });

  final ChatTimelineProjection projection;
  final String? announcement;
  final VoidCallback? onOpenSettings;
  final String? durationLabel;

  @override
  State<ChatTimeline> createState() => _ChatTimelineState();
}

class _ChatTimelineState extends State<ChatTimeline> {
  final _scrollController = ScrollController();
  final Set<String> _expandedReasoning = <String>{};

  @override
  void didUpdateWidget(covariant ChatTimeline oldWidget) {
    super.didUpdateWidget(oldWidget);
    final shouldFollow =
        !_scrollController.hasClients ||
        _scrollController.position.maxScrollExtent -
                _scrollController.position.pixels <=
            DomovoyDimensions.timelineScrollThreshold;
    final validKeys = widget.projection.items
        .whereType<ChatReasoningItem>()
        .map((item) => item.responseKey)
        .toSet();
    _expandedReasoning.removeWhere((key) => !validKeys.contains(key));
    if (shouldFollow &&
        oldWidget.projection.items.length != widget.projection.items.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToEnd());
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final layout = resolveWorkspaceLayout(
      media.size,
      media.textScaler.scale(1),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final contentWidth = math.min(
          layout.timelineMaxWidth,
          constraints.maxWidth,
        );
        final side = math.max(0.0, (constraints.maxWidth - contentWidth) / 2);
        return Stack(
          children: [
            Scrollbar(
              controller: _scrollController,
              thumbVisibility: true,
              thickness: 6,
              radius: const Radius.circular(DomovoyDimensions.space1),
              child: ListView.separated(
                key: const ValueKey('chat-timeline'),
                controller: _scrollController,
                padding: EdgeInsets.fromLTRB(
                  side,
                  DomovoyDimensions.pageInsets.top,
                  side,
                  DomovoyDimensions.space10 * 3 +
                      MediaQuery.viewInsetsOf(context).bottom,
                ),
                itemCount: widget.projection.items.length,
                separatorBuilder: (context, index) =>
                    const SizedBox(height: DomovoyDimensions.space5),
                itemBuilder: (context, index) {
                  final item = widget.projection.items[index];
                  final responseKey = item is ChatReasoningItem
                      ? item.responseKey
                      : item.key;
                  final lastAssistant =
                      item is ChatAssistantItem &&
                      index ==
                          widget.projection.items.lastIndexWhere(
                            (entry) => entry is ChatAssistantItem,
                          );
                  return ChatTimelinePart(
                    key: ValueKey('timeline-part:${item.key}'),
                    item: item,
                    durationLabel: lastAssistant ? widget.durationLabel : null,
                    reasoningExpanded: _expandedReasoning.contains(responseKey),
                    onOpenSettings: widget.onOpenSettings,
                    onReasoningToggle: () {
                      setState(() {
                        if (!_expandedReasoning.add(responseKey)) {
                          _expandedReasoning.remove(responseKey);
                        }
                      });
                    },
                  );
                },
              ),
            ),
            if (widget.announcement != null)
              Semantics(
                key: const ValueKey('chat-live-status'),
                container: true,
                liveRegion: true,
                label: widget.announcement,
                child: const SizedBox.shrink(),
              ),
          ],
        );
      },
    );
  }

  void _scrollToEnd() {
    if (!_scrollController.hasClients) return;
    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
  }
}
