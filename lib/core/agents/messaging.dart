import 'dart:collection';

import '../llm/json.dart';
import '../llm/messages.dart';
import 'errors.dart';
import 'ids.dart';

enum DeliveryStatus { queued, rejected, steered }

enum DeliveryPreference { queuedOnly, preferSteer }

enum RejectionReason { unknown, closed, full, invalid }

final class SessionEnvelope {
  SessionEnvelope({
    required this.id,
    required this.source,
    required this.target,
    required LlmMessage payload,
    required this.acceptedAtMicros,
    this.correlationId,
    this.replyTo,
  }) : payload = _requireUser(payload);

  static LlmMessage _requireUser(LlmMessage payload) {
    if (payload.role != LlmMessageRole.user) {
      throwAgent(
        AgentErrorKind.configuration,
        'Session envelopes must carry user-role payloads.',
      );
    }
    return payload;
  }

  factory SessionEnvelope.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return SessionEnvelope(
      id: MessageId.fromJson(map['id']),
      source: AgentSessionId.fromJson(map['source']),
      target: AgentSessionId.fromJson(map['target']),
      payload: LlmMessage.fromJson(map['payload']),
      acceptedAtMicros: requireInt(map, 'acceptedAtMicros'),
      correlationId: map['correlationId'] == null
          ? null
          : CorrelationId.fromJson(map['correlationId']),
      replyTo: map['replyTo'] == null
          ? null
          : MessageId.fromJson(map['replyTo']),
    );
  }

  static const jsonType = 'agent.session_envelope';

  final MessageId id;
  final AgentSessionId source;
  final AgentSessionId target;
  final LlmMessage payload;
  final int acceptedAtMicros;
  final CorrelationId? correlationId;
  final MessageId? replyTo;

  Map<String, Object?> toJson() {
    final fields = <String, Object?>{
      'id': id.toJson(),
      'source': source.toJson(),
      'target': target.toJson(),
      'payload': payload.toJson(),
      'acceptedAtMicros': acceptedAtMicros,
    };
    if (correlationId != null) {
      fields['correlationId'] = correlationId!.toJson();
    }
    if (replyTo != null) {
      fields['replyTo'] = replyTo!.toJson();
    }
    return typedJson(type: jsonType, fields: fields);
  }

  SessionEnvelope copy() => SessionEnvelope.fromJson(toJson());
}

final class DeliveryReceipt {
  const DeliveryReceipt({
    required this.status,
    required this.messageId,
    this.correlationId,
    this.rejection,
  });

  factory DeliveryReceipt.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    final statusName = requireNonBlankString(map, 'status');
    final status = DeliveryStatus.values
        .where((value) => value.name == statusName)
        .firstOrNull;
    if (status == null) {
      throwAgent(AgentErrorKind.configuration, 'Unknown delivery status.');
    }
    RejectionReason? rejection;
    if (map['rejection'] != null) {
      final name = requireNonBlankString(map, 'rejection');
      rejection = RejectionReason.values
          .where((value) => value.name == name)
          .firstOrNull;
      if (rejection == null) {
        throwAgent(AgentErrorKind.configuration, 'Unknown rejection reason.');
      }
    }
    return DeliveryReceipt(
      status: status,
      messageId: MessageId.fromJson(map['messageId']),
      correlationId: map['correlationId'] == null
          ? null
          : CorrelationId.fromJson(map['correlationId']),
      rejection: rejection,
    );
  }

  static const jsonType = 'agent.delivery_receipt';

  final DeliveryStatus status;
  final MessageId messageId;
  final CorrelationId? correlationId;
  final RejectionReason? rejection;

  Map<String, Object?> toJson() {
    final fields = <String, Object?>{
      'status': status.name,
      'messageId': messageId.toJson(),
    };
    if (correlationId != null) {
      fields['correlationId'] = correlationId!.toJson();
    }
    if (rejection != null) {
      fields['rejection'] = rejection!.name;
    }
    return typedJson(type: jsonType, fields: fields);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeliveryReceipt &&
          other.status == status &&
          other.messageId == messageId &&
          other.correlationId == correlationId &&
          other.rejection == rejection;

  @override
  int get hashCode => Object.hash(status, messageId, correlationId, rejection);
}

abstract interface class SessionMessageRouter {
  Future<DeliveryReceipt> send(
    SessionEnvelope envelope, {
    DeliveryPreference preference = DeliveryPreference.queuedOnly,
  });
}

final class InMemorySessionRouter implements SessionMessageRouter {
  InMemorySessionRouter({
    this.capacity = 100,
    this.closedTrackingLimit = 1024,
  }) {
    if (capacity <= 0) {
      throwAgent(
        AgentErrorKind.configuration,
        'Mailbox capacity must be a positive integer.',
      );
    }
    if (closedTrackingLimit <= 0) {
      throwAgent(
        AgentErrorKind.configuration,
        'Closed-session tracking limit must be a positive integer.',
      );
    }
  }

  final int capacity;
  final int closedTrackingLimit;
  final Set<String> _live = <String>{};
  final LinkedHashSet<String> _closed = LinkedHashSet<String>();
  final Map<String, List<SessionEnvelope>> _mailboxes =
      <String, List<SessionEnvelope>>{};

  void register(AgentSessionId id) {
    if (_live.contains(id.value)) {
      throwAgent(
        AgentErrorKind.configuration,
        'Session ${id.value} is already live in this runtime.',
      );
    }
    _live.add(id.value);
    _closed.remove(id.value);
    _mailboxes.putIfAbsent(id.value, () => <SessionEnvelope>[]);
  }

  void markClosed(AgentSessionId id) {
    _live.remove(id.value);
    _closed.remove(id.value);
    _closed.add(id.value);
    while (_closed.length > closedTrackingLimit) {
      _closed.remove(_closed.first);
    }
  }

  void unregister(AgentSessionId id) {
    _live.remove(id.value);
    _mailboxes.remove(id.value);
  }

  List<SessionEnvelope> drain(AgentSessionId id) {
    final box = _mailboxes[id.value];
    if (box == null || box.isEmpty) {
      return const <SessionEnvelope>[];
    }
    final drained = List<SessionEnvelope>.unmodifiable(
      box.map((envelope) => envelope.copy()),
    );
    box.clear();
    return drained;
  }

  int queuedCount(AgentSessionId id) => _mailboxes[id.value]?.length ?? 0;

  @override
  Future<DeliveryReceipt> send(
    SessionEnvelope envelope, {
    DeliveryPreference preference = DeliveryPreference.queuedOnly,
  }) async {
    final copy = envelope.copy();
    final target = copy.target.value;
    if (_closed.contains(target) ||
        (!_live.contains(target) && _mailboxes[target] == null)) {
      final reason = _closed.contains(target)
          ? RejectionReason.closed
          : RejectionReason.unknown;
      return DeliveryReceipt(
        status: DeliveryStatus.rejected,
        messageId: copy.id,
        correlationId: copy.correlationId,
        rejection: reason,
      );
    }
    if (!_live.contains(target)) {
      return DeliveryReceipt(
        status: DeliveryStatus.rejected,
        messageId: copy.id,
        correlationId: copy.correlationId,
        rejection: RejectionReason.unknown,
      );
    }
    final box = _mailboxes.putIfAbsent(target, () => <SessionEnvelope>[]);
    if (box.length >= capacity) {
      return DeliveryReceipt(
        status: DeliveryStatus.rejected,
        messageId: copy.id,
        correlationId: copy.correlationId,
        rejection: RejectionReason.full,
      );
    }
    box.add(copy);
    return DeliveryReceipt(
      status: DeliveryStatus.queued,
      messageId: copy.id,
      correlationId: copy.correlationId,
    );
  }
}
