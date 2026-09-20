import '../llm/json.dart';
import '../projects/ids.dart';
import 'enums.dart';
import 'errors.dart';
import 'ids.dart';
import 'validation.dart';

/// Default cap on the rendered memory block, in Unicode code points.
const defaultMemoryCharacterBudget = 12000;

/// Default maximum number of long-term records eligible for lexical ranking.
const defaultMaxLongTermRecords = 5;

/// Deterministic input of a memory read plan.
final class MemoryReadRequest {
  MemoryReadRequest({
    required this.projectId,
    String query = '',
    this.characterBudget = defaultMemoryCharacterBudget,
    this.maxLongTermRecords = defaultMaxLongTermRecords,
    this.includeWorking = true,
    this.includeLongTerm = true,
  }) : query = normalizeMemoryQuery(query) {
    if (characterBudget <= 0) {
      throwMemory(
        MemoryErrorKind.configuration,
        'Memory character budget must be positive.',
      );
    }
    if (maxLongTermRecords < 0) {
      throwMemory(
        MemoryErrorKind.configuration,
        'Long-term record cap must be non-negative.',
      );
    }
  }

  factory MemoryReadRequest.fromJson(Object? json) {
    try {
      final map = decodeTypedJson(json, type: jsonType);
      final expected = <String>{
        llmJsonTypeKey,
        llmJsonVersionKey,
        'projectId',
        'query',
        'characterBudget',
        'maxLongTermRecords',
        'includeWorking',
        'includeLongTerm',
      };
      _expectKeys(map, expected, 'memory read request');
      return MemoryReadRequest(
        projectId: ProjectId.fromJson(map['projectId']),
        query: requireString(map, 'query'),
        characterBudget: requireInt(map, 'characterBudget'),
        maxLongTermRecords: requireInt(map, 'maxLongTermRecords'),
        includeWorking: requireBool(map, 'includeWorking'),
        includeLongTerm: requireBool(map, 'includeLongTerm'),
      );
    } on MemoryException {
      rethrow;
    } on Object catch (error) {
      throw wrapMemoryCodecFailure(error);
    }
  }

  static const jsonType = 'memory.read_request';

  final ProjectId projectId;
  final String query;
  final int characterBudget;
  final int maxLongTermRecords;
  final bool includeWorking;
  final bool includeLongTerm;

  Map<String, Object?> toJson() => typedJson(
    type: jsonType,
    fields: <String, Object?>{
      'projectId': projectId.toJson(),
      'query': query,
      'characterBudget': characterBudget,
      'maxLongTermRecords': maxLongTermRecords,
      'includeWorking': includeWorking,
      'includeLongTerm': includeLongTerm,
    },
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MemoryReadRequest &&
          other.projectId == projectId &&
          other.query == query &&
          other.characterBudget == characterBudget &&
          other.maxLongTermRecords == maxLongTermRecords &&
          other.includeWorking == includeWorking &&
          other.includeLongTerm == includeLongTerm;

  @override
  int get hashCode => Object.hash(
    projectId,
    query,
    characterBudget,
    maxLongTermRecords,
    includeWorking,
    includeLongTerm,
  );
}

/// One record supplied to the provider, in deterministic order.
final class MemoryReadPlanItem {
  const MemoryReadPlanItem({
    required this.entryId,
    required this.revision,
    required this.layer,
    required this.scope,
    required this.kind,
    required this.content,
    required this.reason,
  });

  factory MemoryReadPlanItem.fromJson(Object? json) {
    try {
      final map = decodeTypedJson(json, type: jsonType);
      final expected = <String>{
        llmJsonTypeKey,
        llmJsonVersionKey,
        'entryId',
        'revision',
        'layer',
        'scope',
        'kind',
        'content',
        'reason',
      };
      _expectKeys(map, expected, 'memory read plan item');
      return MemoryReadPlanItem(
        entryId: MemoryEntryId.fromJson(map['entryId']),
        revision: requireInt(map, 'revision'),
        layer: MemoryLayerCodec.parse(requireNonBlankString(map, 'layer')),
        scope: MemoryScopeCodec.parse(requireNonBlankString(map, 'scope')),
        kind: MemoryKindCodec.parse(requireNonBlankString(map, 'kind')),
        content: requireString(map, 'content'),
        reason: MemoryReadReasonCodec.parse(
          requireNonBlankString(map, 'reason'),
        ),
      );
    } on MemoryException {
      rethrow;
    } on Object catch (error) {
      throw wrapMemoryCodecFailure(error);
    }
  }

  static const jsonType = 'memory.read_plan_item';

  final MemoryEntryId entryId;
  final int revision;
  final MemoryLayer layer;
  final MemoryScope scope;
  final MemoryKind kind;
  final String content;
  final MemoryReadReason reason;

  Map<String, Object?> toJson() => typedJson(
    type: jsonType,
    fields: <String, Object?>{
      'entryId': entryId.toJson(),
      'revision': revision,
      'layer': layer.name,
      'scope': scope.name,
      'kind': kind.name,
      'content': content,
      'reason': reason.name,
    },
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MemoryReadPlanItem &&
          other.entryId == entryId &&
          other.revision == revision &&
          other.layer == layer &&
          other.scope == scope &&
          other.kind == kind &&
          other.content == content &&
          other.reason == reason;

  @override
  int get hashCode =>
      Object.hash(entryId, revision, layer, scope, kind, content, reason);
}

/// One record considered by retrieval, whether or not it was supplied.
final class MemoryTraceRecord {
  MemoryTraceRecord({
    required this.entryId,
    required this.revision,
    required this.layer,
    required this.scope,
    required this.kind,
    required this.included,
    required this.reason,
    List<MemorySourceId> sourceIds = const <MemorySourceId>[],
  }) : sourceIds = List<MemorySourceId>.unmodifiable(
         List<MemorySourceId>.from(sourceIds),
       ) {
    validateMemorySourceIds(this.sourceIds);
  }

  factory MemoryTraceRecord.fromJson(Object? json) {
    try {
      final map = decodeTypedJson(json, type: jsonType);
      final expected = <String>{
        llmJsonTypeKey,
        llmJsonVersionKey,
        'entryId',
        'revision',
        'layer',
        'scope',
        'kind',
        'included',
        'reason',
        'sourceIds',
      };
      _expectKeys(map, expected, 'memory trace record');
      return MemoryTraceRecord(
        entryId: MemoryEntryId.fromJson(map['entryId']),
        revision: requireInt(map, 'revision'),
        layer: MemoryLayerCodec.parse(requireNonBlankString(map, 'layer')),
        scope: MemoryScopeCodec.parse(requireNonBlankString(map, 'scope')),
        kind: MemoryKindCodec.parse(requireNonBlankString(map, 'kind')),
        included: requireBool(map, 'included'),
        reason: MemoryReadReasonCodec.parse(
          requireNonBlankString(map, 'reason'),
        ),
        sourceIds: requireList(
          map,
          'sourceIds',
        ).map(MemorySourceId.fromJson).toList(growable: false),
      );
    } on MemoryException {
      rethrow;
    } on Object catch (error) {
      throw wrapMemoryCodecFailure(error);
    }
  }

  static const jsonType = 'memory.trace_record';

  final MemoryEntryId entryId;
  final int revision;
  final MemoryLayer layer;
  final MemoryScope scope;
  final MemoryKind kind;
  final bool included;
  final MemoryReadReason reason;
  final List<MemorySourceId> sourceIds;

  Map<String, Object?> toJson() => typedJson(
    type: jsonType,
    fields: <String, Object?>{
      'entryId': entryId.toJson(),
      'revision': revision,
      'layer': layer.name,
      'scope': scope.name,
      'kind': kind.name,
      'included': included,
      'reason': reason.name,
      'sourceIds': sourceIds.map((source) => source.toJson()).toList(),
    },
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MemoryTraceRecord &&
          other.entryId == entryId &&
          other.revision == revision &&
          other.layer == layer &&
          other.scope == scope &&
          other.kind == kind &&
          other.included == included &&
          other.reason == reason &&
          listEquals(other.sourceIds, sourceIds);

  @override
  int get hashCode => Object.hash(
    entryId,
    revision,
    layer,
    scope,
    kind,
    included,
    reason,
    Object.hashAll(sourceIds),
  );
}

/// A deterministic read plan plus its complete audit trail.
final class MemoryReadPlan {
  MemoryReadPlan({
    required this.request,
    List<MemoryReadPlanItem> items = const <MemoryReadPlanItem>[],
    List<MemoryTraceRecord> trace = const <MemoryTraceRecord>[],
  }) : items = List<MemoryReadPlanItem>.unmodifiable(items),
       trace = List<MemoryTraceRecord>.unmodifiable(trace) {
    _validateOrdering();
    final rendered = renderedCharacters;
    if (rendered > request.characterBudget) {
      throwMemory(
        MemoryErrorKind.configuration,
        'A memory read plan must not exceed its character budget.',
      );
    }
    final includedKeys = <String>{
      for (final record in this.trace)
        if (record.included) _recordKey(record.entryId, record.revision),
    };
    if (includedKeys.length != this.items.length) {
      throwMemory(
        MemoryErrorKind.configuration,
        'Included trace records must match the supplied plan items exactly.',
      );
    }
    for (final item in this.items) {
      final matchingTrace = this.trace.cast<MemoryTraceRecord?>().firstWhere(
        (record) =>
            record!.included &&
            record.entryId == item.entryId &&
            record.revision == item.revision,
        orElse: () => null,
      );
      if (matchingTrace == null ||
          matchingTrace.layer != item.layer ||
          matchingTrace.scope != item.scope ||
          matchingTrace.kind != item.kind ||
          matchingTrace.reason != item.reason) {
        throwMemory(
          MemoryErrorKind.configuration,
          'Plan items and included trace records must match exactly.',
        );
      }
    }
  }

  factory MemoryReadPlan.fromJson(Object? json) {
    try {
      final map = decodeTypedJson(json, type: jsonType);
      final expected = <String>{
        llmJsonTypeKey,
        llmJsonVersionKey,
        'request',
        'items',
        'trace',
      };
      _expectKeys(map, expected, 'memory read plan');
      return MemoryReadPlan(
        request: MemoryReadRequest.fromJson(map['request']),
        items: requireList(
          map,
          'items',
        ).map(MemoryReadPlanItem.fromJson).toList(growable: false),
        trace: requireList(
          map,
          'trace',
        ).map(MemoryTraceRecord.fromJson).toList(growable: false),
      );
    } on MemoryException {
      rethrow;
    } on Object catch (error) {
      throw wrapMemoryCodecFailure(error);
    }
  }

  static const jsonType = 'memory.read_plan';

  final MemoryReadRequest request;
  final List<MemoryReadPlanItem> items;
  final List<MemoryTraceRecord> trace;

  int get renderedCharacters =>
      items.fold<int>(0, (sum, item) => sum + item.content.runes.length);

  int get budgetCharacters => request.characterBudget;

  bool get truncated => trace.any(
    (record) =>
        !record.included && record.reason == MemoryReadReason.budgetExceeded,
  );

  MemoryContextTrace get contextTrace => MemoryContextTrace(
    records: trace,
    renderedCharacters: renderedCharacters,
    budgetCharacters: budgetCharacters,
    truncated: truncated,
  );

  Map<String, Object?> toJson() => typedJson(
    type: jsonType,
    fields: <String, Object?>{
      'request': request.toJson(),
      'items': items.map((item) => item.toJson()).toList(),
      'trace': trace.map((record) => record.toJson()).toList(),
    },
  );

  void _validateOrdering() {
    final itemIds = <String>{};
    for (final item in items) {
      if (!itemIds.add(item.entryId.value)) {
        throwMemory(
          MemoryErrorKind.configuration,
          'Read plan items must contain one revision per memory entry.',
        );
      }
    }
    for (var index = 1; index < items.length; index += 1) {
      final previous = items[index - 1];
      final current = items[index];
      if (compareMemoryReadPlanItems(previous, current) >= 0) {
        throwMemory(
          MemoryErrorKind.configuration,
          'Read plan items must be unique and deterministically ordered.',
        );
      }
    }
    final traceIds = <String>{};
    for (final record in trace) {
      if (!traceIds.add(record.entryId.value)) {
        throwMemory(
          MemoryErrorKind.configuration,
          'Trace records must contain one revision per memory entry.',
        );
      }
    }
    for (var index = 1; index < trace.length; index += 1) {
      final previous = trace[index - 1];
      final current = trace[index];
      if (compareMemoryTraceRecords(previous, current) >= 0) {
        throwMemory(
          MemoryErrorKind.configuration,
          'Trace records must be unique and deterministically ordered.',
        );
      }
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MemoryReadPlan &&
          other.request == request &&
          listEquals(other.items, items) &&
          listEquals(other.trace, trace);

  @override
  int get hashCode =>
      Object.hash(request, Object.hashAll(items), Object.hashAll(trace));
}

/// Auditable record of exactly which memory was supplied to the provider.
final class MemoryContextTrace {
  MemoryContextTrace({
    List<MemoryTraceRecord> records = const <MemoryTraceRecord>[],
    required this.renderedCharacters,
    required this.budgetCharacters,
    required this.truncated,
  }) : records = List<MemoryTraceRecord>.unmodifiable(records) {
    if (renderedCharacters < 0) {
      throwMemory(
        MemoryErrorKind.configuration,
        'Rendered characters must be non-negative.',
      );
    }
    if (budgetCharacters <= 0) {
      throwMemory(
        MemoryErrorKind.configuration,
        'Trace budget must be positive.',
      );
    }
    if (renderedCharacters > budgetCharacters) {
      throwMemory(
        MemoryErrorKind.configuration,
        'A memory trace must not exceed its budget.',
      );
    }
    final hasBudgetExclusion = this.records.any(
      (record) =>
          !record.included && record.reason == MemoryReadReason.budgetExceeded,
    );
    if (truncated != hasBudgetExclusion) {
      throwMemory(
        MemoryErrorKind.configuration,
        'Trace truncation must match its budget-excluded records.',
      );
    }
    final recordIds = <String>{};
    for (final record in this.records) {
      if (!recordIds.add(record.entryId.value)) {
        throwMemory(
          MemoryErrorKind.configuration,
          'A context trace must contain one revision per memory entry.',
        );
      }
    }
    for (var index = 1; index < this.records.length; index += 1) {
      if (compareMemoryTraceRecords(
            this.records[index - 1],
            this.records[index],
          ) >=
          0) {
        throwMemory(
          MemoryErrorKind.configuration,
          'Trace records must be unique and deterministically ordered.',
        );
      }
    }
  }

  factory MemoryContextTrace.fromJson(Object? json) {
    try {
      final map = decodeTypedJson(json, type: jsonType);
      final expected = <String>{
        llmJsonTypeKey,
        llmJsonVersionKey,
        'records',
        'renderedCharacters',
        'budgetCharacters',
        'truncated',
      };
      _expectKeys(map, expected, 'memory context trace');
      return MemoryContextTrace(
        records: requireList(
          map,
          'records',
        ).map(MemoryTraceRecord.fromJson).toList(growable: false),
        renderedCharacters: requireInt(map, 'renderedCharacters'),
        budgetCharacters: requireInt(map, 'budgetCharacters'),
        truncated: requireBool(map, 'truncated'),
      );
    } on MemoryException {
      rethrow;
    } on Object catch (error) {
      throw wrapMemoryCodecFailure(error);
    }
  }

  static const jsonType = 'memory.context_trace';

  final List<MemoryTraceRecord> records;
  final int renderedCharacters;
  final int budgetCharacters;
  final bool truncated;

  List<MemoryTraceRecord> get includedRecords =>
      records.where((record) => record.included).toList(growable: false);

  List<MemoryTraceRecord> get excludedRecords =>
      records.where((record) => !record.included).toList(growable: false);

  Map<String, Object?> toJson() => typedJson(
    type: jsonType,
    fields: <String, Object?>{
      'records': records.map((record) => record.toJson()).toList(),
      'renderedCharacters': renderedCharacters,
      'budgetCharacters': budgetCharacters,
      'truncated': truncated,
    },
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MemoryContextTrace &&
          listEquals(other.records, records) &&
          other.renderedCharacters == renderedCharacters &&
          other.budgetCharacters == budgetCharacters &&
          other.truncated == truncated;

  @override
  int get hashCode => Object.hash(
    Object.hashAll(records),
    renderedCharacters,
    budgetCharacters,
    truncated,
  );
}

/// Deterministic ordering for plan items: working before long-term, priority
/// reasons first, then stable identity.
int compareMemoryReadPlanItems(
  MemoryReadPlanItem left,
  MemoryReadPlanItem right,
) {
  final byLayer = left.layer.index.compareTo(right.layer.index);
  if (byLayer != 0) return byLayer;
  final byReason = left.reason.index.compareTo(right.reason.index);
  if (byReason != 0) return byReason;
  return left.entryId.value.compareTo(right.entryId.value);
}

/// Deterministic ordering for trace records: included first, then the same
/// layer/reason/identity ordering as plan items.
int compareMemoryTraceRecords(MemoryTraceRecord left, MemoryTraceRecord right) {
  if (left.included != right.included) {
    return left.included ? -1 : 1;
  }
  final byLayer = left.layer.index.compareTo(right.layer.index);
  if (byLayer != 0) return byLayer;
  final byReason = left.reason.index.compareTo(right.reason.index);
  if (byReason != 0) return byReason;
  return left.entryId.value.compareTo(right.entryId.value);
}

String _recordKey(MemoryEntryId id, int revision) => '${id.value}#$revision';

void _expectKeys(Map<String, Object?> map, Set<String> expected, String label) {
  if (map.keys.length != expected.length ||
      !map.keys.every(expected.contains)) {
    throwMemory(MemoryErrorKind.configuration, 'Unexpected $label fields.');
  }
}
