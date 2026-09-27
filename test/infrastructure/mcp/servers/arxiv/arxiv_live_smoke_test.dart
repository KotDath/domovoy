import 'dart:io';

import 'package:domovoy/infrastructure/mcp/servers/arxiv/arxiv.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// One low-rate live call against the official arXiv API.
///
/// Skipped by default so the normal suite stays hermetic. Run it explicitly:
///
/// ```sh
/// ARXIV_LIVE_SMOKE=1 flutter test \
///   test/infrastructure/mcp/servers/arxiv/arxiv_live_smoke_test.dart
/// ```
///
/// The test performs two requests (search + get_paper) and therefore takes at
/// least the documented three seconds between them.
void main() {
  final enabled = Platform.environment['ARXIV_LIVE_SMOKE'] == '1';

  test(
    'searches arXiv and reads the first paper through the injected adapter',
    () async {
      final client = ArxivClient(
        http: HttpArxivHttpAdapter(),
        requestTimeout: const Duration(seconds: 20),
      );

      final page = await client.search(
        ArxivSearchRequest(query: 'quantum computing', limit: 2),
      );
      expect(
        page.papers,
        isNotEmpty,
        reason: 'live arXiv search returned none',
      );
      for (final paper in page.papers) {
        expect(paper.abstractUrl.host, 'arxiv.org');
        expect(paper.publishedAt.isUtc, isTrue);
        expect(paper.updatedAt.isUtc, isTrue);
        expect(paper.authors, isNotEmpty);
      }

      final paper = await client.getPaper(page.papers.first.displayId);
      expect(paper.arxivId, page.papers.first.arxivId);
      expect(paper.title, isNotEmpty);

      debugPrint(
        'live smoke: search=${page.papers.length} '
        'totalResults=${page.totalResults} '
        'first=${paper.displayId} "${paper.title}"',
      );
    },
    skip: enabled ? false : 'Set ARXIV_LIVE_SMOKE=1 to hit the live arXiv API.',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
