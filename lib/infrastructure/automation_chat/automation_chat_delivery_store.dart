import 'dart:async';
import 'dart:convert';

import '../../core/automation/automation.dart';
import '../agents/jsonl/jsonl_stream_storage.dart';

/// Envelope type of one chat delivery card stream.
const automationChatStreamType = 'domovoy.automation_chat_delivery';

/// Envelope version of the card stream contract.
const automationChatStreamVersion = 1;

/// JSONL store of delivered result cards.
///
/// One immutable card per stream, keyed by [AutomationChatDelivery.deliveryId]
/// (derived from `runId`). The stream is written once and never rewritten:
/// a retried delivery of the same run is answered from the existing stream, so
/// a crash between the terminal run write and the delivery marker cannot
/// produce a second card.
///
/// Replay rules follow the other JSONL stores of the project:
/// - an unknown envelope/record version or a foreign identity is a visible
///   [AutomationErrorKind.corruption] failure, never a partially accepted card;
/// - a trailing fragment without its newline is a truncated write and is
///   ignored (the card is treated as absent);
/// - any other malformed line fails closed.
final class JsonlAutomationChatDeliveryStore
    implements AutomationChatDeliveryStore, AutomationChatDeliverySource {
  JsonlAutomationChatDeliveryStore({required JsonlStreamStorage storage})
    : _storage = storage;

  static const envelopeType = automationChatStreamType;
  static const envelopeVersion = automationChatStreamVersion;

  final JsonlStreamStorage _storage;
  final StreamController<AutomationChatDelivery> _delivered =
      StreamController<AutomationChatDelivery>.broadcast(sync: true);
  Future<void> _pendingWrite = Future<void>.value();
  var _disposed = false;

  @override
  Stream<AutomationChatDelivery> get delivered => _delivered.stream;

  /// Closes the change stream; the store owns no other resource.
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    unawaited(_delivered.close());
  }

  @override
  Future<AutomationChatDelivery?> findByRunId(String runId) {
    final normalized = _normalizeRunId(runId);
    return _read(AutomationChatDelivery.deliveryIdForRun(normalized));
  }

  @override
  Future<AutomationChatDeliveryWrite> saveIfAbsent(
    AutomationChatDelivery delivery,
  ) {
    final result = _pendingWrite.then((_) => _saveIfAbsent(delivery));
    _pendingWrite = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<AutomationChatDeliveryWrite> _saveIfAbsent(
    AutomationChatDelivery delivery,
  ) async {
    final key = delivery.deliveryId;
    final existing = await _read(key);
    if (existing != null) {
      return AutomationChatDeliveryWrite(delivery: existing, created: false);
    }
    final entry = <int>[...utf8.encode(jsonEncode(_envelope(delivery))), 0x0a];
    try {
      await _storage.publish(key, List<int>.unmodifiable(entry));
    } on AutomationException {
      rethrow;
    } on Object {
      throwAutomation(
        AutomationErrorKind.persistence,
        'Карточку результата не удалось сохранить.',
      );
    }
    if (!_disposed && !_delivered.isClosed) {
      _delivered.add(delivery);
    }
    return AutomationChatDeliveryWrite(delivery: delivery, created: true);
  }

  @override
  Future<List<AutomationChatDelivery>> deliveriesForChat(String chatId) async {
    final normalized = _normalizeChatId(chatId);
    final keys = await _listKeys();
    final result = <AutomationChatDelivery>[];
    for (final key in keys) {
      if (!key.startsWith(automationChatDeliveryPrefix)) {
        // Another generation in the shared namespace is not our stream.
        continue;
      }
      final delivery = await _read(key);
      if (delivery == null || delivery.chatId != normalized) {
        continue;
      }
      result.add(delivery);
    }
    result.sort((left, right) {
      final byTime = left.deliveredAt.compareTo(right.deliveredAt);
      return byTime != 0 ? byTime : left.deliveryId.compareTo(right.deliveryId);
    });
    return List<AutomationChatDelivery>.unmodifiable(result);
  }

  Map<String, Object?> _envelope(AutomationChatDelivery delivery) =>
      <String, Object?>{
        'type': envelopeType,
        'version': envelopeVersion,
        'sequence': 0,
        'deliveryId': delivery.deliveryId,
        'chatId': delivery.chatId,
        'runId': delivery.runId.value,
        'payload': delivery.toJson(),
      };

  Future<List<String>> _listKeys() async {
    try {
      return await _storage.listKeys();
    } on AutomationException {
      rethrow;
    } on Object {
      throwAutomation(
        AutomationErrorKind.persistence,
        'Список карточек результата не удалось прочитать.',
      );
    }
  }

  Future<AutomationChatDelivery?> _read(String key) async {
    final Stream<List<int>>? chunks;
    try {
      chunks = await _storage.read(key);
    } on AutomationException {
      rethrow;
    } on Object {
      throwAutomation(
        AutomationErrorKind.persistence,
        'Поток карточки результата не удалось прочитать.',
      );
    }
    if (chunks == null) {
      return null;
    }
    final buffer = StringBuffer();
    var length = 0;
    try {
      await for (final chunk in chunks) {
        length += chunk.length;
        if (length > maxCardStreamBytes) {
          throwAutomation(
            AutomationErrorKind.corruption,
            'Поток карточки результата превышает допустимый размер.',
          );
        }
        buffer.write(utf8.decode(chunk, allowMalformed: true));
      }
    } on AutomationException {
      rethrow;
    } on Object {
      throwAutomation(
        AutomationErrorKind.persistence,
        'Поток карточки результата не удалось прочитать.',
      );
    }
    final text = buffer.toString();
    if (text.isEmpty) {
      return null;
    }
    final lineEnd = text.indexOf('\n');
    if (lineEnd < 0) {
      // A trailing fragment without its newline is a truncated write: the card
      // is not observable yet, and a retry publishes the complete stream.
      return null;
    }
    final line = text.substring(0, lineEnd);
    if (line.trim().isEmpty) {
      throwAutomation(
        AutomationErrorKind.corruption,
        'Поток карточки результата пуст; запись не принята.',
      );
    }
    if (text.substring(lineEnd + 1).trim().isNotEmpty) {
      throwAutomation(
        AutomationErrorKind.corruption,
        'Поток карточки результата содержит лишние записи; '
        'карточка неизменяема.',
      );
    }
    return _decodeLine(key, line);
  }

  AutomationChatDelivery _decodeLine(String key, String line) {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      throwAutomation(
        AutomationErrorKind.corruption,
        'Карточка результата повреждена и не может быть прочитана.',
      );
    }
    if (decoded is! Map) {
      throwAutomation(
        AutomationErrorKind.corruption,
        'Карточка результата повреждена: ожидался JSON-объект.',
      );
    }
    final Map<String, Object?> envelope;
    try {
      envelope = requireJsonObject(decoded, 'Конверт карточки');
    } on AutomationException {
      throwAutomation(
        AutomationErrorKind.corruption,
        'Конверт карточки результата повреждён.',
      );
    }
    final type = envelope['type'];
    final version = envelope['version'];
    final sequence = envelope['sequence'];
    final deliveryId = envelope['deliveryId'];
    final chatId = envelope['chatId'];
    final runId = envelope['runId'];
    if (type != envelopeType ||
        version != envelopeVersion ||
        sequence != 0 ||
        deliveryId is! String ||
        chatId is! String ||
        runId is! String) {
      throwAutomation(
        AutomationErrorKind.corruption,
        'Конверт карточки результата не соответствует контракту.',
      );
    }
    if (deliveryId != key) {
      throwAutomation(
        AutomationErrorKind.corruption,
        'Ключ потока не совпадает с идентификатором карточки.',
      );
    }
    final AutomationChatDelivery delivery;
    try {
      delivery = AutomationChatDelivery.fromJson(envelope['payload']);
    } on AutomationException {
      throwAutomation(
        AutomationErrorKind.corruption,
        'Содержимое карточки результата не прошло проверку.',
      );
    }
    if (delivery.deliveryId != deliveryId ||
        delivery.runId.value != runId ||
        delivery.chatId != chatId) {
      throwAutomation(
        AutomationErrorKind.corruption,
        'Карточка результата противоречит своему конверту.',
      );
    }
    return delivery;
  }

  static String _normalizeRunId(String runId) => AutomationRunId(runId).value;

  static String _normalizeChatId(String chatId) {
    final trimmed = chatId.trim();
    if (trimmed.isEmpty || trimmed.length > 128) {
      throwAutomation(
        AutomationErrorKind.invalidInput,
        'chatId карточки результата должен быть непустой строкой.',
      );
    }
    return trimmed;
  }
}

/// Upper bound of one card stream, shared with the other JSONL stores.
const int maxCardStreamBytes = 512 * 1024;
