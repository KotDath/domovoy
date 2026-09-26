import '../mcp/catalog.dart';
import '../mcp/ids.dart';
import '../mcp/naming.dart';
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

/// Tools that may never run without a person watching, independent of the
/// allowlist a caller passes.
///
/// The built-in `automation` server creates new schedules through
/// `create_task`; a scheduled run that could call it would let an unattended
/// agent extend its own automation. The restriction is keyed by the built-in
/// connection id and original tool name, so a third-party server that happens
/// to expose a tool called `create_task` on another connection is unaffected.
abstract final class ScheduledToolRestrictions {
  /// Connection id of the built-in automation MCP server (B6).
  static const automationConnectionId = 'automation';

  /// Original tool name that creates schedules on the built-in server.
  static const createTaskOriginalName = 'create_task';

  /// Stable model-facing identities every unattended grant denies.
  static final Set<String> intrinsicDeniedToolIds =
      Set<String>.unmodifiable(<String>{
        McpToolNamePolicy().candidate(
          connectionId: McpConnectionId(automationConnectionId),
          originalToolName: createTaskOriginalName,
        ),
      });

  static bool isIntrinsicDenial(String toolId) =>
      intrinsicDeniedToolIds.contains(toolId);
}

/// Explicit, immutable rights for one chat, project or scheduled task.
///
/// The unit is a stable model-facing tool identity (for MCP tools the name
/// derived by the B1 naming policy from `(connectionId, originalToolName)`).
/// Rights are deny-by-default: an identity that is absent from [allowed] is
/// denied even if the model saw it earlier, and a tool removed from the live
/// catalog fails closed before execution.
///
/// An unattended grant ([isUnattended]) additionally denies
/// [ScheduledToolRestrictions.intrinsicDeniedToolIds], so schedule creation
/// stays impossible even when a caller forgets the explicit deny list.
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
       denied = Set<String>.unmodifiable(<String>{
         ..._validatedIds(deniedToolIds, 'denied'),
         // Unattended rights intrinsically exclude schedule creation, so a
         // caller cannot forget the deny list.
         if (!interactiveApproval || scope == ToolAccessScope.scheduledTask)
           ...ScheduledToolRestrictions.intrinsicDeniedToolIds,
       }),
       ask = Set<String>.unmodifiable(_validatedIds(askToolIds, 'ask')) {
    for (final id in ask) {
      if (denied.contains(id) && !isIntrinsicScheduledDenial(id)) {
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
  ///
  /// With [interactiveApproval] disabled (or [scope] set to
  /// [ToolAccessScope.scheduledTask]) the grant is unattended and therefore
  /// also denies [ScheduledToolRestrictions.intrinsicDeniedToolIds].
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
  ///
  /// The built-in `automation.create_task` identity is denied intrinsically:
  /// a scheduled run cannot create new schedules even if [allowedToolIds]
  /// contains it and [deniedToolIds] is empty. Third-party tools named
  /// `create_task` on other connections stay governable by [allowedToolIds].
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

  /// True when no person is watching this run.
  ///
  /// Unattended grants never wait for an approval and always deny
  /// [ScheduledToolRestrictions.intrinsicDeniedToolIds].
  bool get isUnattended =>
      !interactiveApproval || scope == ToolAccessScope.scheduledTask;

  /// True when [toolId] is denied by [ScheduledToolRestrictions] rather than by
  /// the caller's own list (such a denial never conflicts with `ask`).
  bool isIntrinsicScheduledDenial(String toolId) =>
      isUnattended && ScheduledToolRestrictions.isIntrinsicDenial(toolId);

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
