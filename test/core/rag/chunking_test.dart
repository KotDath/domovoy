import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/rag/chunking.dart';
import 'package:domovoy/core/rag/models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/rag_fakes.dart';

void main() {
  final models = FakeRagModels();
  test(
    'fixed windows preserve Unicode slices, bounded size and overlap',
    () async {
      final doc = RagDocument(
        source: 'unicode.md',
        title: 'Unicode',
        text: '\uFEFF# Память\r\nПривет 😀 э́моция\r\n${'абвг ' * 20}',
      );
      final chunker = RagChunker(models, target: 20, overlap: 4);
      final chunks = await chunker.split(
        doc,
        ChunkStrategy.fixed,
        CancellationSource().token,
      );
      expect(chunks.length, greaterThan(2));
      for (final c in chunks) {
        expect(c.tokens, lessThanOrEqualTo(20));
        expect(c.text, doc.text.substring(c.start, c.end));
        expect(c.text.runes.contains(0xfffd), isFalse);
      }
      expect(chunks[1].start, lessThan(chunks[0].end));
      final again = await chunker.split(
        doc,
        ChunkStrategy.fixed,
        CancellationSource().token,
      );
      expect(again.map((c) => c.id), chunks.map((c) => c.id));
      final changed = await RagChunker(
        models,
        target: 20,
        overlap: 2,
      ).split(doc, ChunkStrategy.fixed, CancellationSource().token);
      expect(changed.first.id, isNot(chunks.first.id));
    },
  );
  test('structure recognizes headings but not fenced code headings', () async {
    final doc = RagDocument(
      source: 'structure.md',
      title: 'Test',
      text:
          '# First\n${'one ' * 20}\n```dart\n# Fake\n```\n## Second\n${'two ' * 20}',
    );
    final chunks = await RagChunker(
      models,
      target: 48,
      overlap: 6,
    ).split(doc, ChunkStrategy.structure, CancellationSource().token);
    expect(chunks.any((c) => c.section.contains('Fake')), isFalse);
    expect(chunks.any((c) => c.section == 'First / Second'), isTrue);
    expect(chunks.every((c) => c.tokens <= 48), isTrue);
    expect(chunks.any((c) => c.forcedSplit), isTrue);
  });
  test(
    'fitting code/list/table blocks retain boundaries and PDF numeric prose is not a heading',
    () async {
      final doc = RagDocument(
        source: 'blocks.md',
        title: 'Blocks',
        text:
            '# Title\n\n${'intro ' * 8}\n\n```dart\nline one\nline two\n```\n\n- first item\n- second item\n\n| Col |\n| --- |\n| Val |\n',
      );
      final chunks = await RagChunker(
        models,
        target: 75,
        overlap: 0,
      ).split(doc, ChunkStrategy.structure, CancellationSource().token);
      final codeStart = doc.text.indexOf('```dart');
      final codeEnd = doc.text.indexOf('```', codeStart + 3) + 3;
      expect(
        chunks.any((c) => c.start <= codeStart && c.end >= codeEnd),
        isTrue,
      );
      final pdf = RagDocument(
        source: 'p.pdf',
        title: 'Paper',
        pageStarts: [0],
        text:
            '1 Introduction\nEvidence\n1.2 Background\nMore evidence\n2024 was a year of development\n',
      );
      final pdfChunks = await RagChunker(
        models,
        target: 200,
        overlap: 0,
      ).split(pdf, ChunkStrategy.structure, CancellationSource().token);
      expect(pdfChunks.any((c) => c.section.contains('2024')), isFalse);
      expect(
        pdfChunks.any((c) => c.section == '1 Introduction / 1.2 Background'),
        isTrue,
      );
    },
  );
  test(
    'empty documents produce no chunks and cancellation stops work',
    () async {
      final doc = RagDocument(source: 'empty', title: 'Empty', text: '');
      expect(
        await RagChunker(
          models,
        ).split(doc, ChunkStrategy.fixed, CancellationSource().token),
        isEmpty,
      );
      final cancelled = CancellationSource()..cancel();
      await expectLater(
        RagChunker(models).split(doc, ChunkStrategy.fixed, cancelled.token),
        throwsA(isA<RagCancelled>()),
      );
    },
  );
}
