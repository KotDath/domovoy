import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/mcp/mcp.dart';
import 'package:domovoy/core/projects/projects.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/agent_harness.dart';
import '../../support/mcp_fakes.dart';

void main() {
  group('explicit tool access grants', () {
    test('deny by default and explicit denial wins', () {
      final grant = ToolAccessGrant(
        allowedToolIds: <String>['mcp_alpha__search'],
        deniedToolIds: <String>['mcp_alpha__danger'],
      );
      expect(grant.permits('mcp_alpha__search'), isTrue);
      // A tool the grant never saw (for example added by a catalog refresh).
      expect(grant.permissionFor('mcp_alpha__brand_new'), ToolPermission.deny);
      expect(grant.permissionFor('mcp_alpha__danger'), ToolPermission.deny);
      expect(grant.permissionFor('read'), ToolPermission.deny);
    });

    test('ask becomes deny when interactive approval is impossible', () {
      final interactive = ToolAccessGrant(
        allowedToolIds: <String>['mcp_alpha__write'],
        askToolIds: <String>['mcp_alpha__write'],
      );
      expect(interactive.permissionFor('mcp_alpha__write'), ToolPermission.ask);

      final scheduled = ToolAccessGrant(
        allowedToolIds: <String>['mcp_alpha__write'],
        askToolIds: <String>['mcp_alpha__write'],
        interactiveApproval: false,
        scope: ToolAccessScope.scheduledTask,
      );
      expect(scheduled.permissionFor('mcp_alpha__write'), ToolPermission.deny);
    });

    test('rejects contradictory grants instead of guessing', () {
      final denied = ToolAccessGrant(
        allowedToolIds: <String>['x'],
        deniedToolIds: <String>['x'],
      );
      // An explicit denial wins over an allow entry.
      expect(denied.permissionFor('x'), ToolPermission.deny);
      expect(
        () => ToolAccessGrant(
          allowedToolIds: <String>['x'],
          askToolIds: <String>['y'],
        ),
        throwsA(isA<AgentException>()),
      );
      expect(
        () => ToolAccessGrant(allowedToolIds: <String>[' ']),
        throwsA(isA<AgentException>()),
      );
    });

    test('catalog grants add destructive tools to the approval set only', () {
      final catalog = McpCatalogBuilder().build();
      final builder = McpCatalogBuilder();
      builder.addConnection(McpConnectionId('alpha'), <McpToolDescriptor>[
        scriptedTool(
          'alpha',
          'search',
          annotations: const <String, Object?>{'destructiveHint': true},
        ),
        scriptedTool('alpha', 'read_only'),
      ]);
      final built = builder.build();
      expect(catalog.isEmpty, isTrue);

      final grant = ToolAccessGrant.forMcpCatalog(
        catalog: built,
        allowedToolIds: <String>['mcp_alpha__search', 'mcp_alpha__read_only'],
      );
      expect(grant.permissionFor('mcp_alpha__search'), ToolPermission.ask);
      expect(grant.permissionFor('mcp_alpha__read_only'), ToolPermission.allow);
      expect(grant.permissionFor('mcp_alpha__other'), ToolPermission.deny);

      final scheduled = ToolAccessGrant.forMcpCatalog(
        catalog: built,
        allowedToolIds: <String>['mcp_alpha__search'],
        interactiveApproval: false,
        scope: ToolAccessScope.scheduledTask,
      );
      expect(scheduled.permissionFor('mcp_alpha__search'), ToolPermission.deny);
    });

    test('scheduled grants deny task creation explicitly', () {
      final grant = ToolAccessGrant.scheduledTask(
        allowedToolIds: <String>[
          'mcp_automation__list_tasks',
          'mcp_arxiv__search',
        ],
        deniedToolIds: <String>['mcp_automation__create_task'],
      );
      expect(grant.interactiveApproval, isFalse);
      expect(grant.scope, ToolAccessScope.scheduledTask);
      expect(grant.permits('mcp_automation__list_tasks'), isTrue);
      expect(
        grant.permissionFor('mcp_automation__create_task'),
        ToolPermission.deny,
      );
      expect(grant.permits('mcp_automation__run_task_now'), isFalse);
    });

    test(
      'scheduled grants intrinsically deny the built-in create_task route',
      () {
        final grant = ToolAccessGrant.scheduledTask(
          allowedToolIds: <String>[
            'mcp_automation__create_task',
            'mcp_automation__list_tasks',
            'mcp_other__create_task',
          ],
        );
        expect(grant.isUnattended, isTrue);
        // Denied without any caller-supplied deny list.
        expect(
          grant.permissionFor('mcp_automation__create_task'),
          ToolPermission.deny,
        );
        expect(grant.permits('mcp_automation__list_tasks'), isTrue);
        // A third-party create_task on another connection stays governable.
        expect(grant.permits('mcp_other__create_task'), isTrue);

        final builder = McpCatalogBuilder();
        builder.addConnection(
          McpConnectionId('automation'),
          <McpToolDescriptor>[
            scriptedTool(
              'automation',
              'create_task',
              annotations: const <String, Object?>{'destructiveHint': true},
            ),
            scriptedTool('automation', 'list_tasks'),
          ],
        );
        final scheduled = ToolAccessGrant.forMcpCatalog(
          catalog: builder.build(),
          allowedToolIds: <String>[
            'mcp_automation__create_task',
            'mcp_automation__list_tasks',
          ],
          interactiveApproval: false,
          scope: ToolAccessScope.scheduledTask,
        );
        // The destructive annotation would add create_task to the approval set;
        // the intrinsic denial wins instead of raising a conflict.
        expect(
          scheduled.permissionFor('mcp_automation__create_task'),
          ToolPermission.deny,
        );
        expect(scheduled.permits('mcp_automation__list_tasks'), isTrue);
      },
    );

    test('an interactive grant keeps the built-in create_task governable', () {
      final scheduled = ToolAccessGrant.scheduledTask(
        allowedToolIds: <String>['mcp_automation__create_task'],
      );
      expect(scheduled.permits('mcp_automation__create_task'), isFalse);

      final interactive = ToolAccessGrant(
        allowedToolIds: <String>['mcp_automation__create_task'],
      );
      expect(interactive.isUnattended, isFalse);
      expect(interactive.permits('mcp_automation__create_task'), isTrue);
    });

    test('policy delegates every decision to the grant', () {
      final policy = ToolAccessPolicy(
        id: PolicyId('chat-42'),
        grant: ToolAccessGrant(allowedToolIds: <String>['read']),
      );
      expect(policy.id, PolicyId('chat-42'));
      ToolPermission decide(String name) => policy.decide(
        ToolInvocation(
          callId: 'call-1',
          name: name,
          arguments: const <String, Object?>{},
        ),
      );
      expect(decide('read'), ToolPermission.allow);
      expect(decide('bash'), ToolPermission.deny);
    });

    test('a project-scoped policy denies other projects', () {
      final policy = ToolAccessPolicy(
        grant: ToolAccessGrant(
          allowedToolIds: <String>['read'],
          scope: ToolAccessScope.project,
        ),
        projectId: ProjectId('alpha'),
      );
      ToolPermission decide(ProjectId? project) => policy.decide(
        ToolInvocation(
          callId: 'call-1',
          name: 'read',
          arguments: const <String, Object?>{},
          projectId: project,
        ),
      );
      expect(decide(ProjectId('alpha')), ToolPermission.allow);
      expect(decide(ProjectId('beta')), ToolPermission.deny);
      expect(decide(null), ToolPermission.deny);
    });
  });

  group('agent definition migration', () {
    test('old session records stay interactive and byte-compatible', () {
      final definition = testDefinition(tools: <ToolId>[ToolId('read')]);
      final json = definition.toJson();
      expect(json.containsKey('interactiveApproval'), isFalse);
      final restored = AgentDefinition.fromJson(json);
      expect(restored.interactiveApproval, isTrue);

      final legacy = Map<String, Object?>.from(json);
      expect(AgentDefinition.fromJson(legacy).interactiveApproval, isTrue);

      final scheduled = AgentDefinition(
        id: AgentId('scheduler'),
        name: 'Scheduled',
        systemPrompt: 'Run.',
        model: definition.model,
        interactiveApproval: false,
      );
      final scheduledJson = scheduled.toJson();
      expect(scheduledJson['interactiveApproval'], isFalse);
      expect(
        AgentDefinition.fromJson(scheduledJson).interactiveApproval,
        isFalse,
      );
    });
  });
}
