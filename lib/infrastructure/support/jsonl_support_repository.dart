import 'dart:async';
import 'dart:convert';

import '../../core/support/support.dart';
import '../agents/jsonl/jsonl_stream_storage.dart';

/// One atomic JSONL journal; replay validates identity and every revision.
final class JsonlSupportRepository implements SupportRepository {
  JsonlSupportRepository(this.storage);
  final JsonlStreamStorage storage;
  Future<void> _tail = Future.value();

  Future<T> _serial<T>(Future<T> Function() work) {
    final future = _tail.then((_) => work());
    _tail = future.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return future;
  }

  Future<_State> _read() async {
    final stream = await storage.read('support');
    final text = stream == null
        ? ''
        : await stream.transform(utf8.decoder).join();
    if (text.isNotEmpty && !text.endsWith('\n')) {
      throw const FormatException('Incomplete support journal');
    }
    final lines = const LineSplitter().convert(text);
    final state = _State(lines);
    for (final line in lines) {
      final event = jsonDecode(line) as Map<String, dynamic>;
      if (event['version'] != 1) {
        throw const FormatException('Support journal version');
      }
      if (event['kind'] == 'owner') {
        if (state.owner != null) throw const FormatException('Duplicate owner');
        state.owner = event['id'] as String;
      } else if (event['kind'] == 'ticket') {
        final ticket = SupportTicket.fromJson(
          event['ticket'] as Map<String, dynamic>,
        );
        final previous = state.tickets[ticket.id];
        if (!_validTicket(ticket, previous, state.owner)) {
          throw const FormatException('Invalid support revision or identity');
        }
        state.tickets[ticket.id] = ticket;
      } else {
        throw const FormatException('Unknown support event');
      }
    }
    return state;
  }

  Future<void> _append(_State state, Map<String, Object?> event) async {
    await storage.publish(
      'support',
      utf8.encode(
        '${[
          ...state.lines,
          jsonEncode({'version': 1, ...event}),
        ].join('\n')}\n',
      ),
    );
    // Publication is already acknowledged. GC must not turn a durable save
    // into a false failure. The storage serializes cleanup with publication
    // and preserves the active generation; the repository serializes mutations.
    try {
      await storage.cleanup('support');
    } on Object {
      // A later successful mutation retries obsolete-generation cleanup.
    }
    // Re-read on every operation: an uncertain failed publish cannot poison
    // an in-memory cache or falsely advance the owner's/ticket's revision.
  }

  @override
  Future<String> owner() => _serial(() async {
    final state = await _read();
    if (state.owner != null) return state.owner!;
    final id = newSupportId();
    await _append(state, {'kind': 'owner', 'id': id});
    return id;
  });
  @override
  Future<List<SupportTicket>> list() => _serial(
    () async =>
        (await _read()).tickets.values.toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)),
  );
  @override
  Future<SupportTicket?> load(String id) =>
      _serial(() async => (await _read()).tickets[id]);
  @override
  Future<void> save(SupportTicket ticket, {required int? expectedRevision}) =>
      _serial(() async {
        final state = await _read();
        final previous = state.tickets[ticket.id];
        if (previous?.revision != expectedRevision ||
            !_validTicket(ticket, previous, state.owner)) {
          throw StateError(
            'Обращение изменилось. Обновите список и повторите.',
          );
        }
        await _append(state, {'kind': 'ticket', 'ticket': ticket.toJson()});
      });
}

bool _validTicket(
  SupportTicket ticket,
  SupportTicket? previous,
  String? owner,
) =>
    owner != null &&
    ticket.ownerId == owner &&
    RegExp(r'^[a-f0-9]{48}$').hasMatch(ticket.id) &&
    ticket.subject.trim().isNotEmpty &&
    ticket.subject.length <= 160 &&
    ticket.description.trim().isNotEmpty &&
    ticket.description.length <= 6000 &&
    ticket.sessionId.value == '$supportSessionPrefix${ticket.id}' &&
    ticket.createdAt > 0 &&
    ticket.updatedAt >= ticket.createdAt &&
    ticket.revision == (previous == null ? 0 : previous.revision + 1) &&
    (previous == null ||
        (previous.createdAt == ticket.createdAt &&
            previous.subject == ticket.subject &&
            previous.description == ticket.description &&
            previous.projectId == ticket.projectId &&
            previous.updatedAt <= ticket.updatedAt &&
            !(previous.ready && !ticket.ready)));

final class _State {
  _State(this.lines);
  final List<String> lines;
  String? owner;
  final tickets = <String, SupportTicket>{};
}
