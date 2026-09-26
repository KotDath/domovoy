import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:mcp_dart/mcp_dart.dart';

typedef ArchiveSearch =
    Future<Map<String, Object?>> Function(String query, int limit);

/// Calls the other MCP server instead of bypassing it with a second API client.
final class ArchiveMcpSource {
  const ArchiveMcpSource(this.endpoint);

  final Uri endpoint;

  Future<Map<String, Object?>> search(String query, int limit) async {
    final client = McpClient(
      const Implementation(name: 'domovoy-briefing', version: '1.0.0'),
      options: const McpClientOptions(protocol: McpProtocol.stable),
    );
    try {
      await client.connect(StreamableHttpClientTransport(endpoint));
      final result = await client.callTool(
        CallToolRequest(
          name: 'archive_search',
          arguments: {'query': query, 'limit': limit},
        ),
        options: const RequestOptions(timeout: Duration(seconds: 30)),
      );
      if (result.isError) {
        throw StateError('Archive search failed.');
      }
      final value = result.structuredContent;
      if (value == null) {
        throw const FormatException(
          'Archive search returned no structured result.',
        );
      }
      return Map<String, Object?>.from(value);
    } finally {
      await client.close();
    }
  }
}

/// JSONL event store and scheduler. It remains active without a Flutter app.
final class BriefingService {
  BriefingService({
    required this.dataFile,
    required this.searchArchive,
    DateTime Function()? now,
    this.pollInterval = const Duration(seconds: 1),
  }) : now = now ?? DateTime.now,
       assert(pollInterval > Duration.zero);

  final File dataFile;
  final ArchiveSearch searchArchive;
  final DateTime Function() now;
  final Duration pollInterval;
  final Map<String, Map<String, Object?>> _schedules = {};
  final List<Map<String, Object?>> _reports = [];
  final Set<String> _running = {};
  final Set<String> _cancelled = {};
  final Set<Future<void>> _backgroundRuns = {};
  Future<void> _writes = Future<void>.value();
  Timer? _timer;

  Future<void> start() async {
    await dataFile.parent.create(recursive: true);
    if (await dataFile.exists()) {
      for (final line in await dataFile.readAsLines()) {
        if (line.trim().isEmpty) continue;
        final event = jsonDecode(line);
        if (event is! Map<String, dynamic>) continue;
        switch (event['type']) {
          case 'schedule':
            final schedule = event['schedule'];
            if (schedule is Map<String, dynamic> && schedule['id'] is String) {
              _schedules[schedule['id'] as String] = Map<String, Object?>.from(
                schedule,
              );
            }
          case 'report':
            final report = event['report'];
            if (report is Map<String, dynamic>) {
              _reports.add(Map<String, Object?>.from(report));
            }
          case 'cancel':
            final id = event['id'];
            if (id is String) {
              _cancelled.add(id);
              _schedules.remove(id);
            }
        }
      }
    }
    _timer = Timer.periodic(pollInterval, (_) => _runInBackground());
    _runInBackground();
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await Future.wait(_backgroundRuns.toList());
    await _writes;
  }

  void _runInBackground() {
    late final Future<void> run;
    run = runDue().then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
      _backgroundRuns.remove(run);
    });
    _backgroundRuns.add(run);
  }

  Map<String, Object?> summarize(Map<String, Object?> searchResult) {
    final query = searchResult['query']?.toString() ?? '';
    final rawItems = searchResult['items'];
    if (rawItems is! List) {
      throw const FormatException('items must be an array.');
    }
    final items = <Map<String, Object?>>[];
    for (final raw in rawItems.take(20)) {
      if (raw is! Map) continue;
      final item = Map<String, Object?>.from(raw);
      final title = item['title']?.toString().trim() ?? '';
      final description = item['description']?.toString().trim() ?? '';
      final source = item['url']?.toString() ?? '';
      items.add({
        'identifier': item['identifier'],
        'title': title,
        'summary': description.length > 240
            ? '${description.substring(0, 240)}…'
            : description,
        'url': source,
      });
    }
    final text = items.isEmpty
        ? 'По запросу «$query» материалы не найдены.'
        : 'По запросу «$query» найдено ${searchResult['total'] ?? items.length} материалов. '
              'В сводку вошли ${items.length}: ${items.map((item) => item['title']).join('; ')}.';
    return {
      'query': query,
      'total': searchResult['total'] ?? items.length,
      'count': items.length,
      'summary': text,
      'items': items,
    };
  }

  Future<Map<String, Object?>> save(
    Map<String, Object?> digest, {
    String? scheduleId,
  }) async {
    final report = <String, Object?>{
      ...digest,
      'id': _id(),
      'createdAt': now().toUtc().toIso8601String(),
      'scheduleId': ?scheduleId,
    };
    await _append({'type': 'report', 'report': report});
    _reports.add(report);
    return report;
  }

  Future<Map<String, Object?>> schedule(
    String query,
    int intervalSeconds, {
    int limit = 5,
  }) async {
    if (query.trim().isEmpty ||
        query.length > 200 ||
        intervalSeconds < 1 ||
        intervalSeconds > 86400 ||
        limit < 1 ||
        limit > 20) {
      throw const FormatException('Invalid query, interval, or limit.');
    }
    final schedule = <String, Object?>{
      'id': _id(),
      'query': query.trim(),
      'limit': limit,
      'intervalSeconds': intervalSeconds,
      'nextRunAt': now().toUtc().toIso8601String(),
      'runCount': 0,
      'lastError': null,
    };
    await _putSchedule(schedule);
    return schedule;
  }

  Future<Map<String, Object?>> cancel(String id) async {
    if (!_schedules.containsKey(id)) {
      throw const FormatException('Schedule not found.');
    }
    _cancelled.add(id);
    await _append({'type': 'cancel', 'id': id});
    _schedules.remove(id);
    return {'id': id, 'cancelled': true};
  }

  List<Map<String, Object?>> schedules() => _schedules.values
      .map((value) => Map<String, Object?>.from(value))
      .toList();

  List<Map<String, Object?>> reports({String? scheduleId}) => [
    for (final report in _reports.reversed)
      if (scheduleId == null || report['scheduleId'] == scheduleId)
        Map<String, Object?>.from(report),
  ];

  Future<Map<String, Object?>> runDue() async {
    var completed = 0;
    var failed = 0;
    final due = _schedules.values
        .where((schedule) {
          final id = schedule['id'] as String;
          final next = DateTime.tryParse(
            schedule['nextRunAt']?.toString() ?? '',
          );
          return !_running.contains(id) && next != null && !next.isAfter(now());
        })
        .map((value) => Map<String, Object?>.from(value))
        .toList();
    for (final schedule in due) {
      final id = schedule['id'] as String;
      if (!_running.add(id)) continue;
      try {
        final result = await searchArchive(
          schedule['query'] as String,
          schedule['limit'] as int,
        );
        await save(summarize(result), scheduleId: id);
        schedule['runCount'] = (schedule['runCount'] as int) + 1;
        schedule['lastError'] = null;
        completed++;
      } on Object catch (error) {
        schedule['lastError'] = '$error';
        failed++;
      } finally {
        if (!_cancelled.contains(id)) {
          schedule['nextRunAt'] = now()
              .toUtc()
              .add(Duration(seconds: schedule['intervalSeconds'] as int))
              .toIso8601String();
          await _putSchedule(schedule);
        }
        _running.remove(id);
      }
    }
    return {
      'due': due.length,
      'completed': completed,
      'failed': failed,
      'reportCount': _reports.length,
    };
  }

  Future<void> _putSchedule(Map<String, Object?> schedule) async {
    await _append({'type': 'schedule', 'schedule': schedule});
    _schedules[schedule['id'] as String] = schedule;
  }

  Future<void> _append(Map<String, Object?> event) {
    final next = _writes.then((_) async {
      await dataFile.writeAsString(
        '${jsonEncode(event)}\n',
        mode: FileMode.append,
        flush: true,
      );
    });
    _writes = next;
    return next;
  }

  String _id() =>
      '${now().microsecondsSinceEpoch.toRadixString(36)}-'
      '${Random.secure().nextInt(1 << 30).toRadixString(36)}';
}
