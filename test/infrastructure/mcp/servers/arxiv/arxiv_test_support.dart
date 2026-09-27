import 'dart:async';

import 'package:domovoy/core/research/research.dart';
import 'package:domovoy/infrastructure/mcp/servers/arxiv/arxiv.dart';

/// Virtual clock so rate limiting and cache TTL never slow tests down.
final class FakeArxivClock implements ArxivClock {
  FakeArxivClock({DateTime? now}) : _now = now ?? DateTime.utc(2025, 1, 1);

  DateTime _now;
  final List<Duration> sleeps = <Duration>[];

  @override
  DateTime nowUtc() => _now;

  @override
  Future<void> sleep(Duration duration) async {
    if (duration <= Duration.zero) {
      return;
    }
    sleeps.add(duration);
    _now = _now.add(duration);
  }

  void advance(Duration duration) {
    _now = _now.add(duration);
  }
}

/// Scripted HTTP adapter that never touches the network.
final class FakeArxivHttpAdapter implements ArxivHttpAdapter {
  FakeArxivHttpAdapter({required this.clock, this.responder});

  final ArxivClock clock;

  /// Returns the response for call [callIndex]; throwing simulates a failure.
  final Future<ArxivHttpResponse> Function(Uri url, int callIndex)? responder;

  final List<Uri> requests = <Uri>[];
  final List<DateTime> requestTimes = <DateTime>[];
  int active = 0;
  int maxActive = 0;

  @override
  Future<ArxivHttpResponse> get(Uri url, {required Duration timeout}) async {
    final index = requests.length;
    requests.add(url);
    requestTimes.add(clock.nowUtc());
    active += 1;
    if (active > maxActive) {
      maxActive = active;
    }
    try {
      final handler = responder;
      if (handler == null) {
        throw StateError('FakeArxivHttpAdapter has no responder');
      }
      return await handler(url, index);
    } finally {
      active -= 1;
    }
  }
}

/// Adapter that answers calls from [responses] in order.
FakeArxivHttpAdapter adapterWithResponses(
  FakeArxivClock clock,
  List<ArxivHttpResponse> responses,
) {
  return FakeArxivHttpAdapter(
    clock: clock,
    responder: (url, index) async {
      if (index >= responses.length) {
        throw StateError('Unexpected arXiv request #$index to $url');
      }
      return responses[index];
    },
  );
}

/// Builds an Atom feed around [entries]; values are inserted verbatim.
String atomFeed({
  List<String> entries = const <String>[],
  String? totalResults,
  String? startIndex,
  String? itemsPerPage,
}) {
  final buffer = StringBuffer()
    ..write('<?xml version="1.0" encoding="utf-8"?>\n')
    ..write(
      '<feed xmlns="http://www.w3.org/2005/Atom" '
      'xmlns:opensearch="http://a9.com/-/spec/opensearch/1.1/" '
      'xmlns:arxiv="http://arxiv.org/schemas/atom">\n',
    )
    ..write('<title>ArXiv Query: search_query=all:test</title>\n')
    ..write('<id>http://arxiv.org/api/test</id>\n')
    ..write('<updated>2025-01-01T00:00:00-05:00</updated>\n');
  if (totalResults != null) {
    buffer.write(
      '<opensearch:totalResults>$totalResults</opensearch:totalResults>\n',
    );
  }
  if (startIndex != null) {
    buffer.write(
      '<opensearch:startIndex>$startIndex</opensearch:startIndex>\n',
    );
  }
  buffer.write(
    '<opensearch:itemsPerPage>'
    '${itemsPerPage ?? entries.length}</opensearch:itemsPerPage>\n',
  );
  for (final entry in entries) {
    buffer
      ..write(entry)
      ..write('\n');
  }
  buffer.write('</feed>');
  return buffer.toString();
}

/// Builds one Atom entry; [escape] can be disabled to test entity decoding.
String atomEntry({
  String id = 'http://arxiv.org/abs/2501.01234v1',
  String title = 'Example title',
  String summary = 'Example abstract',
  List<String> authors = const <String>['A. Researcher'],
  List<String> categories = const <String>['cs.AI'],
  String? primaryCategory,
  String published = '2025-01-03T12:00:00-05:00',
  String updated = '2025-01-06T12:00:00-05:00',
  String? extra,
  bool escape = true,
  bool includeAuthors = true,
  String? declaration,
}) {
  String value(String raw) => escape ? _xmlEscape(raw) : raw;
  final buffer = StringBuffer()
    ..writeln(
      '<entry xmlns="http://www.w3.org/2005/Atom" '
      'xmlns:arxiv="http://arxiv.org/schemas/atom">',
    );
  if (declaration != null) {
    buffer.writeln(declaration);
  }
  buffer
    ..writeln('<id>${value(id)}</id>')
    ..writeln('<published>${value(published)}</published>')
    ..writeln('<updated>${value(updated)}</updated>')
    ..writeln('<title>${value(title)}</title>')
    ..writeln('<summary>${value(summary)}</summary>');
  if (includeAuthors) {
    for (final author in authors) {
      buffer.writeln('<author><name>${value(author)}</name></author>');
    }
  }
  if (primaryCategory != null) {
    buffer.writeln(
      '<arxiv:primary_category term="${value(primaryCategory)}"/>',
    );
  }
  for (final category in categories) {
    buffer.writeln(
      '<category term="${value(category)}" '
      'scheme="http://arxiv.org/schemas/atom"/>',
    );
  }
  if (extra != null) {
    buffer.writeln(extra);
  }
  buffer.writeln('</entry>');
  return buffer.toString();
}

/// Minimal Paper fixture matching [atomEntry] defaults.
Paper paperFixture({
  String arxivId = '2501.01234',
  String? version = 'v1',
  String title = 'Example title',
  List<String> authors = const <String>['A. Researcher'],
  String abstractText = 'Example abstract',
  List<String> categories = const <String>['cs.AI'],
  DateTime? publishedAt,
  DateTime? updatedAt,
}) {
  return Paper(
    arxivId: arxivId,
    version: version,
    title: title,
    authors: authors,
    abstractText: abstractText,
    categories: categories,
    publishedAt: publishedAt ?? DateTime.utc(2025, 1, 3, 17),
    updatedAt: updatedAt ?? DateTime.utc(2025, 1, 6, 17),
  );
}

ArxivHttpResponse atomResponse(
  String body, {
  int statusCode = 200,
  Map<String, String> headers = const <String, String>{},
}) {
  return ArxivHttpResponse(
    statusCode: statusCode,
    body: body,
    headers: headers,
  );
}

String _xmlEscape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
