import 'dart:convert';

import '../llm/cancellation.dart';
import '../llm/json.dart';
import '../llm/tools.dart';
import '../projects/ids.dart';
import 'errors.dart';
import 'ids.dart';
import 'policies.dart';
import 'schema.dart';
import 'tool_schema.dart';

final class ToolInvocation {
  ToolInvocation({
    required this.callId,
    required this.name,
    required Map<String, Object?> arguments,
    this.projectId,
  }) : arguments = freezeJsonMap(copyJsonMap(arguments));

  final String callId;
  final String name;
  final Map<String, Object?> arguments;
  final ProjectId? projectId;
}

final class ToolExecutionResult {
  ToolExecutionResult.success(Object? output)
    : success = true,
      output = deepFreezeJson(output),
      errorMessage = null,
      errorDetails = null;

  /// [details] carries untrusted, but structurally preserved, failure payload
  /// (for example an MCP `structuredContent` returned together with
  /// `isError`). It reaches the transcript as data under `details`; it can
  /// never turn a failure into a success.
  ToolExecutionResult.failure(String message, {Object? details})
    : success = false,
      output = null,
      errorMessage = sanitizePublicText(
        message,
        fallback: 'Tool execution failed.',
      ),
      errorDetails = details == null ? null : deepFreezeJson(details);

  final bool success;
  final Object? output;
  final String? errorMessage;
  final Object? errorDetails;

  String get transcriptContent {
    if (success) {
      return jsonEncode(output ?? <String, Object?>{});
    }
    return jsonEncode(<String, Object?>{
      'error': sanitizePublicText(
        errorMessage,
        fallback: 'Tool execution failed.',
      ),
      if (errorDetails != null) 'details': errorDetails,
    });
  }
}

abstract interface class ToolExecutionLiveness {
  void reportProgress({String? detail});
}

abstract interface class AgentToolExecutor {
  Future<ToolExecutionResult> execute(
    ToolInvocation invocation, {
    required CancellationToken cancellation,
    required ToolExecutionLiveness liveness,
  });
}

/// Validates decoded tool arguments against the tool contract.
///
/// MCP tools install a full JSON Schema validator here; Pi tools keep the
/// original subset validator. The runtime always calls this before a call is
/// permitted, so arguments are checked against the exact schema that was
/// advertised to the provider.
typedef ToolArgumentValidator = void Function(Map<String, Object?> arguments);

/// Result of projecting one tool for a concrete provider profile.
sealed class ToolDescriptorProjection {
  const ToolDescriptorProjection();

  bool get isAvailable;

  LlmToolDescriptor? get descriptor;

  String? get reason;
}

final class AvailableToolDescriptor extends ToolDescriptorProjection {
  const AvailableToolDescriptor(this.descriptor);

  @override
  final LlmToolDescriptor descriptor;

  @override
  bool get isAvailable => true;

  @override
  String? get reason => null;
}

final class UnavailableToolDescriptor extends ToolDescriptorProjection {
  const UnavailableToolDescriptor(this.reason);

  @override
  bool get isAvailable => false;

  @override
  LlmToolDescriptor? get descriptor => null;

  @override
  final String reason;
}

final class AgentTool {
  AgentTool({
    required this.descriptor,
    required this.executor,
    this.binding,
    this.unavailableReason,
    ToolArgumentValidator? argumentValidator,
    ToolDescriptorProjection Function(ToolSchemaProfile profile)?
    descriptorProjector,
  }) : _argumentValidator =
           argumentValidator ?? _descriptorArgumentValidator(descriptor),
       _descriptorProjector = descriptorProjector {
    if (unavailableReason == null && descriptorProjector == null) {
      // Static tools keep the original, narrow contract check at registration.
      validateToolSchema(descriptor.parameters);
    }
  }

  ToolId get id => ToolId(descriptor.name);

  final LlmToolDescriptor descriptor;
  final AgentToolExecutor executor;

  /// Opaque identity used to re-check a call immediately before execution.
  ///
  /// Static tools leave it `null`; dynamic tools (MCP) expose a value object
  /// that changes when the route or schema behind the name changes.
  final Object? binding;

  /// Set when the tool is known but cannot be offered to the model.
  final String? unavailableReason;

  final ToolArgumentValidator _argumentValidator;
  final ToolDescriptorProjection Function(ToolSchemaProfile profile)?
  _descriptorProjector;

  bool get isAvailable => unavailableReason == null;

  void validateArguments(Map<String, Object?> arguments) =>
      _argumentValidator(arguments);

  ToolDescriptorProjection describeFor(ToolSchemaProfile profile) =>
      _descriptorProjector?.call(profile) ??
      AvailableToolDescriptor(descriptor);
}

ToolArgumentValidator _descriptorArgumentValidator(
  LlmToolDescriptor descriptor,
) {
  return (arguments) => validateArguments(descriptor.parameters, arguments);
}

/// Immutable name-to-tool view published by a dynamic [AgentToolSource].
final class AgentToolSourceView {
  AgentToolSourceView({
    required Map<String, AgentTool> tools,
    Map<String, String> unavailable = const <String, String>{},
  }) : tools = Map<String, AgentTool>.unmodifiable(tools),
       unavailable = Map<String, String>.unmodifiable(unavailable);

  static final AgentToolSourceView empty = AgentToolSourceView(
    tools: const <String, AgentTool>{},
  );

  /// Model-facing name to tool.
  final Map<String, AgentTool> tools;

  /// Model-facing name to the reason it cannot be offered.
  final Map<String, String> unavailable;
}

/// A dynamic set of agent tools whose membership changes at runtime.
///
/// The MCP bridge implements this: a catalog refresh replaces [view] and
/// notifies listeners, while the registry keeps a stable, atomically rebuilt
/// merged map. Listeners are synchronous and must not throw.
abstract interface class AgentToolSource {
  String get sourceId;

  AgentToolSourceView get view;

  void addListener(void Function() listener);

  void removeListener(void Function() listener);

  void dispose();
}

final class AgentToolUnavailableNotice {
  const AgentToolUnavailableNotice({required this.id, required this.reason});

  final ToolId id;
  final String reason;
}

/// Per-provider view of the tools enabled for one run.
final class AgentToolView {
  AgentToolView({
    required List<LlmToolDescriptor> descriptors,
    required List<AgentToolUnavailableNotice> unavailable,
  }) : descriptors = List<LlmToolDescriptor>.unmodifiable(descriptors),
       unavailable = List<AgentToolUnavailableNotice>.unmodifiable(unavailable);

  static final AgentToolView empty = AgentToolView(
    descriptors: const <LlmToolDescriptor>[],
    unavailable: const <AgentToolUnavailableNotice>[],
  );

  /// Descriptors to advertise to the provider.
  final List<LlmToolDescriptor> descriptors;

  /// Enabled tools that exist but cannot be represented for this provider.
  final List<AgentToolUnavailableNotice> unavailable;
}

final class AgentToolRegistry {
  final Map<String, AgentTool> _tools = <String, AgentTool>{};
  final Map<String, AgentToolSource> _sources = <String, AgentToolSource>{};
  final Map<String, AgentTool> _dynamic = <String, AgentTool>{};
  final Map<String, String> _unavailable = <String, String>{};
  var _sourceRevision = 0;

  /// Monotonic revision of the merged dynamic view.
  int get sourceRevision => _sourceRevision;

  void register(AgentTool tool) {
    if (_tools.containsKey(tool.descriptor.name) ||
        _dynamic.containsKey(tool.descriptor.name)) {
      throwAgent(
        AgentErrorKind.configuration,
        'Tool "${tool.descriptor.name}" is already registered.',
      );
    }
    _tools[tool.descriptor.name] = tool;
  }

  /// Attaches a dynamic source and merges its current view.
  void attachSource(AgentToolSource source) {
    if (_sources.containsKey(source.sourceId)) {
      throwAgent(
        AgentErrorKind.configuration,
        'Tool source "${source.sourceId}" is already attached.',
      );
    }
    _sources[source.sourceId] = source;
    source.addListener(_rebuildDynamic);
    _rebuildDynamic();
  }

  void detachSource(String sourceId) {
    final source = _sources.remove(sourceId);
    if (source == null) {
      return;
    }
    source.removeListener(_rebuildDynamic);
    _rebuildDynamic();
  }

  /// Detaches every dynamic source; callers own the sources themselves.
  void dispose() {
    for (final source in _sources.values.toList(growable: false)) {
      source.removeListener(_rebuildDynamic);
    }
    _sources.clear();
    _rebuildDynamic();
  }

  AgentTool? lookup(String name) => _tools[name] ?? _dynamic[name];

  bool contains(ToolId id) => lookup(id.value) != null;

  /// Visible reason an enabled tool cannot be offered, when known.
  String? unavailableReason(String name) => _unavailable[name];

  /// Static tools plus the merged dynamic view, ordered by the registry.
  Iterable<AgentTool> get allTools => <AgentTool>[
    ..._tools.values,
    ..._dynamic.values,
  ];

  AgentToolView view(Iterable<ToolId> enabled, {ToolSchemaProfile? profile}) {
    final effective = profile ?? ToolSchemaProfile.openaiChatCompletions;
    final descriptors = <LlmToolDescriptor>[];
    final unavailable = <AgentToolUnavailableNotice>[];
    final seen = <String>{};
    for (final id in enabled) {
      if (!seen.add(id.value)) {
        continue;
      }
      final tool = lookup(id.value);
      if (tool == null) {
        // Unknown ids keep the historical behaviour: an enabled tool that is
        // simply not registered on this platform is not an error.
        continue;
      }
      final reason = tool.unavailableReason;
      if (reason != null) {
        unavailable.add(AgentToolUnavailableNotice(id: id, reason: reason));
        continue;
      }
      final projection = tool.describeFor(effective);
      if (!projection.isAvailable) {
        unavailable.add(
          AgentToolUnavailableNotice(
            id: id,
            reason: projection.reason ?? 'Tool is not available.',
          ),
        );
        continue;
      }
      descriptors.add(projection.descriptor!);
    }
    return AgentToolView(descriptors: descriptors, unavailable: unavailable);
  }

  /// Legacy helper without an explicit provider profile.
  List<LlmToolDescriptor> descriptorsFor(Iterable<ToolId> enabled) =>
      view(enabled).descriptors;

  void _rebuildDynamic() {
    final merged = <String, AgentTool>{};
    final unavailable = <String, String>{};
    final owners = <String, String>{};
    final sources = _sources.values.toList()
      ..sort((a, b) => a.sourceId.compareTo(b.sourceId));
    for (final source in sources) {
      final view = source.view;
      for (final entry in view.tools.entries) {
        final name = entry.key;
        if (_tools.containsKey(name)) {
          unavailable[name] = 'Tool name is already owned by a built-in tool.';
          continue;
        }
        final owner = owners[name];
        if (owner != null) {
          unavailable[name] = 'Tool name is already owned by "$owner".';
          continue;
        }
        owners[name] = source.sourceId;
        merged[name] = entry.value;
      }
      for (final entry in view.unavailable.entries) {
        unavailable.putIfAbsent(entry.key, () => entry.value);
      }
    }
    _dynamic
      ..clear()
      ..addAll(merged);
    _unavailable
      ..clear()
      ..addAll(unavailable);
    _sourceRevision += 1;
  }
}

abstract interface class ToolPermissionPolicy {
  PolicyId get id;

  ToolPermission decide(ToolInvocation invocation);
}

final class DenyAllPolicy implements ToolPermissionPolicy {
  const DenyAllPolicy();

  @override
  PolicyId get id => PolicyId('deny');

  @override
  ToolPermission decide(ToolInvocation invocation) => ToolPermission.deny;
}

final class AllowAllPolicy implements ToolPermissionPolicy {
  const AllowAllPolicy();

  @override
  PolicyId get id => PolicyId('allow');

  @override
  ToolPermission decide(ToolInvocation invocation) => ToolPermission.allow;
}

abstract interface class ToolApprovalHandler {
  Future<bool> approve(ToolInvocation invocation);
}

final _secretPattern = RegExp(
  r'(sk-[A-Za-z0-9]+)|api[_-]?key|bearer\s+\S+|-----BEGIN',
  caseSensitive: false,
);

String sanitizePublicText(String? raw, {required String fallback}) {
  if (raw == null) {
    return fallback;
  }
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return fallback;
  }
  if (_secretPattern.hasMatch(trimmed) ||
      trimmed.contains('\n') ||
      trimmed.contains('StateError') ||
      trimmed.contains('Exception') ||
      trimmed.contains('#0 ') ||
      trimmed.contains('.dart:')) {
    return fallback;
  }
  return trimmed;
}

Map<String, Object?> decodeToolArguments(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) {
    return freezeJsonMap(const <String, Object?>{});
  }
  late final Object? decoded;
  try {
    decoded = jsonDecode(trimmed);
  } on Object {
    throwAgent(
      AgentErrorKind.configuration,
      'Tool arguments must be valid JSON.',
    );
  }
  final object = asJsonObject(decoded);
  if (object == null) {
    throwAgent(
      AgentErrorKind.configuration,
      'Tool arguments must be a JSON object.',
    );
  }
  return freezeJsonMap(object);
}
