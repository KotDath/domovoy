import 'package:flutter/foundation.dart';

import '../../../core/mcp/mcp.dart';
import '../../../core/research/research.dart';

/// Read-only view of the device library. Every read goes through the `library`
/// MCP tools, so the UI never opens a second repository or storage namespace.
final class LibraryController extends ChangeNotifier {
  LibraryController(this.host);

  final McpHost host;
  List<LibraryCard> cards = const [];
  LibraryRecord? selected;
  String? nextCursor;
  String? error;
  String query = '';
  bool loading = false;
  bool loadingDetail = false;
  int _generation = 0;
  int _detailGeneration = 0;
  bool _disposed = false;

  Future<void> refresh({String? search}) async {
    if (_disposed) return;
    if (search != null) query = search;
    final generation = ++_generation;
    final requestedQuery = query.trim();
    loading = true;
    error = null;
    notifyListeners();
    try {
      final payload = await _read('list_saved', {
        if (requestedQuery.isNotEmpty) 'query': requestedQuery,
        'limit': 30,
      });
      if (!_isCurrent(generation)) return;
      final records = payload['records'];
      if (payload['schemaVersion'] != 1 || records is! List) {
        throw const FormatException('Ответ списка библиотеки повреждён.');
      }
      cards = List<LibraryCard>.unmodifiable(records.map(LibraryCard.fromJson));
      nextCursor = payload['nextCursor'] as String?;
    } on Object catch (failure) {
      if (_isCurrent(generation)) error = _message(failure);
    } finally {
      if (_isCurrent(generation)) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadMore() async {
    if (_disposed) return;
    final cursor = nextCursor;
    if (cursor == null || loading) return;
    final generation = _generation;
    final requestedQuery = query.trim();
    loading = true;
    error = null;
    notifyListeners();
    try {
      final payload = await _read('list_saved', {
        if (requestedQuery.isNotEmpty) 'query': requestedQuery,
        'limit': 30,
        'cursor': cursor,
      });
      final records = payload['records'];
      if (!_isCurrent(generation)) return;
      if (payload['schemaVersion'] != 1 || records is! List) {
        throw const FormatException('Ответ списка библиотеки повреждён.');
      }
      cards = List<LibraryCard>.unmodifiable([
        ...cards,
        ...records.map(LibraryCard.fromJson),
      ]);
      nextCursor = payload['nextCursor'] as String?;
    } on Object catch (failure) {
      if (_isCurrent(generation)) error = _message(failure);
    } finally {
      if (_isCurrent(generation)) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> open(LibraryId id) async {
    if (_disposed) return;
    final generation = ++_detailGeneration;
    loadingDetail = true;
    error = null;
    selected = null;
    notifyListeners();
    try {
      final record = LibraryRecord.fromJson(
        await _read('get_saved', {'libraryId': id.value}),
      );
      if (_isCurrentDetail(generation)) selected = record;
    } on Object catch (failure) {
      if (_isCurrentDetail(generation)) error = _message(failure);
    } finally {
      if (_isCurrentDetail(generation)) {
        loadingDetail = false;
        notifyListeners();
      }
    }
  }

  void closeDetail() {
    if (_disposed) return;
    _detailGeneration += 1;
    loadingDetail = false;
    selected = null;
    notifyListeners();
  }

  Future<Map<String, Object?>> _read(
    String toolName,
    Map<String, Object?> arguments,
  ) async {
    McpToolRoute? route;
    for (final candidate in host.snapshot.catalog.routes) {
      if (candidate.connectionId.value == 'library' &&
          candidate.originalToolName == toolName) {
        route = candidate;
        break;
      }
    }
    if (route == null) {
      throw const FormatException('Сервер библиотеки сейчас недоступен.');
    }
    final response = await host.callTool(
      modelToolName: route.modelToolName.value,
      arguments: arguments,
    );
    if (response.isError) {
      throw FormatException(
        response.textContent.isEmpty
            ? 'Не удалось прочитать библиотеку.'
            : response.textContent,
      );
    }
    final payload = response.structuredContent;
    if (payload is! Map) {
      throw const FormatException('Сервер библиотеки вернул пустой ответ.');
    }
    return Map<String, Object?>.from(payload);
  }

  String _message(Object failure) => failure is FormatException
      ? failure.message
      : 'Не удалось прочитать библиотеку на этом устройстве.';

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  bool _isCurrentDetail(int generation) =>
      !_disposed && generation == _detailGeneration;

  @override
  void dispose() {
    _disposed = true;
    _generation += 1;
    _detailGeneration += 1;
    super.dispose();
  }
}
