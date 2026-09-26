import '../mcp/catalog.dart';
import '../projects/ids.dart';
import 'errors.dart';
import 'ids.dart';
import 'policies.dart';
import 'tools.dart';

/// Where an explicit tool allowlist comes from.
enum ToolAccessScope {
  /// One interactive chat.
  chat,

  /// One project shared by its chats.
  project,

  /// One scheduled task run without a person watching.
  scheduledTask,
}

/// Explicit, immutable rights for one chat, project or scheduled task.
///
/// The unit is a stable model-facing tool identity (for MCP tools the name
/// derived by the B1 naming policy from `(connectionId, originalToolName)`).
/// Rights are deny-by-default: an identity that is absent from [allowed] is
/// denied even if the model saw it earlier, and a tool removed from the live
/// catalog fails closed before execution.
final class ToolAccessGrant {
  ToolAccessGrant({
    required Iterable<String> allowedToolIds,
    Iterable<String> deniedToolIds = const <String>[],
    Iterable<String> askToolIds = const <String>[],
    this.interactiveApproval = true,
    this.scope = ToolAccessScope.chat,
  }) : allowed = Set<String>.unmodifiable(
         _validatedIds(allowedToolIds, 'allowed'),
       ),
       denied = Set<String>.unmodifiable(
         _validatedIds(deniedToolIds, 'denied'),
       ),
       ask = Set<String>.unmodifiable(_validatedIds(askToolIds, 'ask')) {
    for (final id in ask) {
      if (denied.contains(id)) {
        throwAgent(
          AgentErrorKind.configuration,
          'Tool "$id" is both denied and awaiting approval.',
        );
      }
      if (!allowed.contains(id)) {
        throwAgent(
          AgentErrorKind.configuration,
          'Tool "$id" awaits approval but is not allowed.',
        );
      }
    }
  }

  /// Builds a grant from the live MCP catalog.
  ///
  /// Tools whose server annotation is `destructiveHint: true` are added to the
  /// approval set unless [askOnDestructive] is disabled. Annotations are
  /// untrusted server data, but using them only to *require* approval is
  /// fail-safe: they can never widen access. The set of allowed identities is
  /// still exactly [allowedToolIds].
  factory ToolAccessGrant.forMcpCatalog({
    required McpCatalog catalog,
    required Iterable<String> allowedToolIds,
    Iterable<String> deniedToolIds = const <String>[],
    bool askOnDestructive = true,
    bool interactiveApproval = true,
    ToolAccessScope scope = ToolAccessScope.chat,
  }) {
    final allowed = _validatedIds(allowedToolIds, 'allowed');
    final ask = <String>{};
    if (askOnDestructive) {
      for (final route in catalog.routes) {
        final name = route.modelToolName.value;
        if (!allowed.contains(name)) {
          continue;
        }
        if (route.descriptor.annotations?['destructiveHint'] == true) {
          ask.add(name);
        }
      }
    }
    return ToolAccessGrant(
      allowedToolIds: allowed,
      deniedToolIds: deniedToolIds,
      askToolIds: ask,
      interactiveApproval: interactiveApproval,
      scope: scope,
    );
  }

  /// A scheduled task never waits for an interactive approval.
  factory ToolAccessGrant.scheduledTask({
    required Iterable<String> allowedToolIds,
    Iterable<String> deniedToolIds = const <String>[],
  }) {
    return ToolAccessGrant(
      allowedToolIds: allowedToolIds,
      deniedToolIds: deniedToolIds,
      interactiveApproval: false,
      scope: ToolAccessScope.scheduledTask,
    );
  }

  final Set<String> allowed;
  final Set<String> denied;
  final Set<String> ask;

  /// When false, an `ask` decision is denied instead of prompting.
  final bool interactiveApproval;

  final ToolAccessScope scope;

  ToolPermission permissionFor(String toolId) {
    if (denied.contains(toolId)) {
      // An explicit denial always wins, even if the id also appears in the
      // allow list (for example a task-creation tool in a scheduled grant).
      return ToolPermission.deny;
    }
    if (!allowed.contains(toolId)) {
      // Deny by default: new tools and tools the grant never saw.
      return ToolPermission.deny;
    }
    if (ask.contains(toolId)) {
      return interactiveApproval ? ToolPermission.ask : ToolPermission.deny;
    }
    return ToolPermission.allow;
  }

  bool permits(String toolId) => permissionFor(toolId) == ToolPermission.allow;
}

/// [ToolPermissionPolicy] backed by an explicit [ToolAccessGrant].
///
/// The runtime calls [decide] immediately before every tool call and again
/// after an interactive approval returned, so a grant that changed while the
/// user was deciding cannot be bypassed by an awaited approval. When
/// [projectId] is set, calls from any other project (including a chat without
/// a project) are denied: project rights never leak to another workspace.
final class ToolAccessPolicy implements ToolPermissionPolicy {
  ToolAccessPolicy({PolicyId? id, required this.grant, this.projectId})
    : id = id ?? PolicyId(grant.scope.name);

  @override
  final PolicyId id;

  final ToolAccessGrant grant;

  /// Optional project this grant is bound to.
  final ProjectId? projectId;

  @override
  ToolPermission decide(ToolInvocation invocation) {
    final bound = projectId;
    if (bound != null && invocation.projectId != bound) {
      return ToolPermission.deny;
    }
    return grant.permissionFor(invocation.name);
  }
}

Set<String> _validatedIds(Iterable<String> values, String label) {
  final result = <String>{};
  for (final value in values) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throwAgent(
        AgentErrorKind.configuration,
        'Tool access $label ids must not be blank.',
      );
    }
    result.add(trimmed);
  }
  return result;
}
