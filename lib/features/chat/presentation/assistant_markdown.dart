import 'package:flutter/material.dart';

import '../../../design_system/design_system.dart';

class AssistantMarkdown extends StatelessWidget {
  const AssistantMarkdown({
    required this.data,
    this.partial = false,
    super.key,
  });

  final String data;
  final bool partial;

  @override
  Widget build(BuildContext context) {
    final tokens = context.domovoyTheme;
    final blocks = _parseBlocks(data);
    if (blocks.isEmpty) {
      return SelectableText(
        data,
        style: Theme.of(context).textTheme.bodyMedium,
      );
    }
    return Semantics(
      label: partial ? 'Частичный ответ ассистента' : 'Ответ ассистента',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < blocks.length; i++) ...[
            if (i > 0) const SizedBox(height: DomovoyDimensions.space4),
            _BlockView(block: blocks[i], tokens: tokens),
          ],
        ],
      ),
    );
  }
}

sealed class _Block {
  const _Block();
}

final class _ParagraphBlock extends _Block {
  const _ParagraphBlock(this.text);
  final String text;
}

final class _HeadingBlock extends _Block {
  const _HeadingBlock(this.level, this.text);
  final int level;
  final String text;
}

final class _ListBlock extends _Block {
  const _ListBlock(this.ordered, this.items);
  final bool ordered;
  final List<String> items;
}

final class _CodeBlock extends _Block {
  const _CodeBlock(this.text);
  final String text;
}

final class _PlainBlock extends _Block {
  const _PlainBlock(this.text);
  final String text;
}

List<_Block> _parseBlocks(String source) {
  final blocks = <_Block>[];
  final lines = source.split('\n');
  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    if (line.startsWith('```')) {
      final body = <String>[];
      i += 1;
      var closed = false;
      while (i < lines.length) {
        if (lines[i].startsWith('```')) {
          closed = true;
          i += 1;
          break;
        }
        body.add(lines[i]);
        i += 1;
      }
      if (closed) {
        blocks.add(_CodeBlock(body.join('\n')));
      } else {
        blocks.add(
          _PlainBlock('```${body.isEmpty ? '' : '\n${body.join('\n')}'}'),
        );
      }
      continue;
    }
    final heading = RegExp(r'^(#{1,3})\s+(.*)$').firstMatch(line);
    if (heading != null) {
      blocks.add(_HeadingBlock(heading.group(1)!.length, heading.group(2)!));
      i += 1;
      continue;
    }
    if (RegExp(r'^\s*[-*]\s+').hasMatch(line) ||
        RegExp(r'^\s*\d+\.\s+').hasMatch(line)) {
      final ordered = RegExp(r'^\s*\d+\.\s+').hasMatch(line);
      final items = <String>[];
      while (i < lines.length) {
        final current = lines[i];
        final match = ordered
            ? RegExp(r'^\s*\d+\.\s+(.*)$').firstMatch(current)
            : RegExp(r'^\s*[-*]\s+(.*)$').firstMatch(current);
        if (match == null) break;
        items.add(match.group(1)!);
        i += 1;
      }
      blocks.add(_ListBlock(ordered, items));
      continue;
    }
    if (line.trim().isEmpty) {
      i += 1;
      continue;
    }
    final paragraph = <String>[line];
    i += 1;
    while (i < lines.length &&
        lines[i].trim().isNotEmpty &&
        !lines[i].startsWith('```') &&
        !RegExp(r'^(#{1,3})\s+').hasMatch(lines[i]) &&
        !RegExp(r'^\s*[-*]\s+').hasMatch(lines[i]) &&
        !RegExp(r'^\s*\d+\.\s+').hasMatch(lines[i])) {
      paragraph.add(lines[i]);
      i += 1;
    }
    blocks.add(_ParagraphBlock(paragraph.join(' ')));
  }
  return blocks;
}

class _BlockView extends StatelessWidget {
  const _BlockView({required this.block, required this.tokens});

  final _Block block;
  final DomovoyThemeTokens tokens;

  @override
  Widget build(BuildContext context) {
    final body = Theme.of(context).textTheme.bodyMedium;
    return switch (block) {
      _HeadingBlock(:final level, :final text) => SelectableText.rich(
        TextSpan(children: _inlineSpans(context, text, tokens)),
        style:
            (level == 1
                    ? Theme.of(context).textTheme.headlineSmall
                    : level == 2
                    ? Theme.of(context).textTheme.titleLarge
                    : Theme.of(context).textTheme.titleSmall)
                ?.copyWith(color: tokens.textPrimary),
      ),
      _ParagraphBlock(:final text) => SelectableText.rich(
        TextSpan(style: body, children: _inlineSpans(context, text, tokens)),
      ),
      _PlainBlock(:final text) => SelectableText(text, style: body),
      _CodeBlock(:final text) => DomovoySurface(
        role: DomovoySurfaceRole.sidebar,
        border: true,
        borderRadius: BorderRadius.circular(DomovoyDimensions.radiusSmall),
        padding: DomovoyDimensions.controlInsets,
        child: SelectableText(
          text,
          style: body?.copyWith(
            fontFamily: 'monospace',
            fontSize: 13,
            height: 1.45,
          ),
        ),
      ),
      _ListBlock(:final ordered, :final items) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var index = 0; index < items.length; index++)
            Padding(
              padding: const EdgeInsets.only(bottom: DomovoyDimensions.space2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: DomovoyDimensions.space6,
                    child: Text(ordered ? '${index + 1}.' : '•', style: body),
                  ),
                  Expanded(
                    child: SelectableText.rich(
                      TextSpan(
                        style: body,
                        children: _inlineSpans(context, items[index], tokens),
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    };
  }
}

List<InlineSpan> _inlineSpans(
  BuildContext context,
  String source,
  DomovoyThemeTokens tokens,
) {
  final spans = <InlineSpan>[];
  final pattern = RegExp(
    r'(\*\*[^*]+\*\*|\*[^*]+\*|`[^`]+`|\[[^\]]+\]\([^)]+\)|<[^>]+>|!\[[^\]]*\]\([^)]+\))',
  );
  var cursor = 0;
  for (final match in pattern.allMatches(source)) {
    if (match.start > cursor) {
      spans.add(TextSpan(text: source.substring(cursor, match.start)));
    }
    final token = match.group(0)!;
    if (token.startsWith('**') && token.endsWith('**')) {
      spans.add(
        TextSpan(
          text: token.substring(2, token.length - 2),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      );
    } else if (token.startsWith('*') && token.endsWith('*')) {
      spans.add(
        TextSpan(
          text: token.substring(1, token.length - 1),
          style: const TextStyle(fontStyle: FontStyle.italic),
        ),
      );
    } else if (token.startsWith('`') && token.endsWith('`')) {
      spans.add(
        TextSpan(
          text: token.substring(1, token.length - 1),
          style: TextStyle(
            fontFamily: 'monospace',
            backgroundColor: tokens.sidebar,
          ),
        ),
      );
    } else if (token.startsWith('[')) {
      final label =
          RegExp(r'\[([^\]]+)\]').firstMatch(token)?.group(1) ?? token;
      spans.add(
        TextSpan(
          text: label,
          style: TextStyle(
            color: tokens.accent,
            decoration: TextDecoration.underline,
          ),
        ),
      );
    } else if (token.startsWith('![')) {
      spans.add(
        TextSpan(
          text: token,
          style: TextStyle(color: tokens.textMuted),
        ),
      );
    } else {
      spans.add(TextSpan(text: token));
    }
    cursor = match.end;
  }
  if (cursor < source.length) {
    spans.add(TextSpan(text: source.substring(cursor)));
  }
  return spans;
}
