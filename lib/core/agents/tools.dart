import 'dart:convert';

import '../llm/cancellation.dart';
import '../llm/json.dart';
import '../llm/tools.dart';
import 'errors.dart';
import 'ids.dart';
import 'policies.dart';
import 'schema.dart';

final class ToolInvocation {
  ToolInvocation({
    required this.callId,
    required this.name,
    required Map<String, Object?> arguments,
  }) : arguments = freezeJsonMap(copyJsonMap(arguments));

  final String callId;
  final String name;
  final Map<String, Object?> arguments;
}

final class ToolExecutionResult {
  ToolExecutionResult.success(Object? output)
    : success = true,
      output = deepFreezeJson(output),
      errorMessage = null;

  ToolExecutionResult.failure(String message)
    : success = false,
      output = null,
      errorMessage = sanitizePublicText(
        message,
        fallback: 'Tool execution failed.',
      );

  final bool success;
  final Object? output;
  final String? errorMessage;

  String get transcriptContent {
    if (success) {
      return jsonEncode(output ?? <String, Object?>{});
    }
    return jsonEncode(<String, Object?>{'error': errorMessage});
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

final class AgentTool {
  AgentTool({required this.descriptor, required this.executor}) {
    validateToolSchema(descriptor.parameters);
  }

  ToolId get id => ToolId(descriptor.name);

  final LlmToolDescriptor descriptor;
  final AgentToolExecutor executor;
}

final class AgentToolRegistry {
  final Map<String, AgentTool> _tools = <String, AgentTool>{};

  void register(AgentTool tool) {
    if (_tools.containsKey(tool.descriptor.name)) {
      throwAgent(
        AgentErrorKind.configuration,
        'Tool "${tool.descriptor.name}" is already registered.',
      );
    }
    _tools[tool.descriptor.name] = tool;
  }

  AgentTool? lookup(String name) => _tools[name];

  bool contains(ToolId id) => _tools.containsKey(id.value);

  List<LlmToolDescriptor> descriptorsFor(Iterable<ToolId> enabled) {
    return [
      for (final id in enabled)
        if (_tools[id.value] != null) _tools[id.value]!.descriptor,
    ];
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
