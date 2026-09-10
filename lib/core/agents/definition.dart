import '../llm/generation.dart';
import '../llm/identifiers.dart';
import '../llm/json.dart';
import '../llm/messages.dart';
import 'errors.dart';
import 'ids.dart';
import 'policies.dart';

final class AgentDefinition {
  AgentDefinition({
    required this.id,
    required String name,
    required String systemPrompt,
    required this.model,
    List<LlmMessage> initialMessages = const <LlmMessage>[],
    LlmGenerationConfig? generation,
    List<ToolId> enabledTools = const <ToolId>[],
    PolicyId? policy,
    this.limits,
    this.liveness,
    this.noProgress,
    this.budget,
  }) : name = name.trim(),
       systemPrompt = systemPrompt.trim(),
       initialMessages = List<LlmMessage>.unmodifiable(
         List<LlmMessage>.from(initialMessages),
       ),
       generation = generation ?? LlmGenerationConfig.defaults,
       enabledTools = List<ToolId>.unmodifiable(
         List<ToolId>.from(enabledTools),
       ),
       policy = policy ?? PolicyId('deny') {
    if (this.name.isEmpty) {
      throwAgent(AgentErrorKind.configuration, 'Agent name must not be blank.');
    }
    final seen = <String>{};
    for (final tool in this.enabledTools) {
      if (!seen.add(tool.value)) {
        throwAgent(
          AgentErrorKind.configuration,
          'Duplicate enabled tool "${tool.value}".',
        );
      }
    }
  }

  factory AgentDefinition.fromJson(Object? json) {
    final map = decodeTypedJson(json, type: jsonType);
    return AgentDefinition(
      id: AgentId.fromJson(map['id']),
      name: requireString(map, 'name'),
      systemPrompt: requireString(map, 'systemPrompt'),
      model: ModelRef.fromJson(map['model']),
      initialMessages: requireList(
        map,
        'initialMessages',
      ).map(LlmMessage.fromJson).toList(),
      generation: map['generation'] == null
          ? null
          : LlmGenerationConfig.fromJson(map['generation']),
      enabledTools: requireList(
        map,
        'enabledTools',
      ).map(ToolId.fromJson).toList(),
      policy: map['policy'] == null ? null : PolicyId.fromJson(map['policy']),
      limits: map['limits'] == null
          ? null
          : AgentRunLimits.fromJson(map['limits']),
      liveness: map['liveness'] == null
          ? null
          : AgentLivenessPolicy.fromJson(map['liveness']),
      noProgress: map['noProgress'] == null
          ? null
          : AgentNoProgressPolicy.fromJson(map['noProgress']),
      budget: map['budget'] == null
          ? null
          : AgentTokenBudget.fromJson(map['budget']),
    );
  }

  static const jsonType = 'agent.definition';

  final AgentId id;
  final String name;
  final String systemPrompt;
  final List<LlmMessage> initialMessages;
  final ModelRef model;
  final LlmGenerationConfig generation;
  final List<ToolId> enabledTools;
  final PolicyId policy;
  final AgentRunLimits? limits;
  final AgentLivenessPolicy? liveness;
  final AgentNoProgressPolicy? noProgress;
  final AgentTokenBudget? budget;

  Map<String, Object?> toJson() {
    final fields = <String, Object?>{
      'id': id.toJson(),
      'name': name,
      'systemPrompt': systemPrompt,
      'initialMessages': initialMessages
          .map((message) => message.toJson())
          .toList(),
      'model': model.toJson(),
      'generation': generation.toJson(),
      'enabledTools': enabledTools.map((tool) => tool.toJson()).toList(),
      'policy': policy.toJson(),
    };
    if (limits != null) {
      fields['limits'] = limits!.toJson();
    }
    if (liveness != null) {
      fields['liveness'] = liveness!.toJson();
    }
    if (noProgress != null) {
      fields['noProgress'] = noProgress!.toJson();
    }
    if (budget != null) {
      fields['budget'] = budget!.toJson();
    }
    return typedJson(type: jsonType, fields: fields);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentDefinition &&
          other.id == id &&
          other.name == name &&
          other.systemPrompt == systemPrompt &&
          listEquals(other.initialMessages, initialMessages) &&
          other.model == model &&
          other.generation == generation &&
          listEquals(other.enabledTools, enabledTools) &&
          other.policy == policy &&
          other.limits == limits &&
          other.liveness == liveness &&
          other.noProgress == noProgress &&
          other.budget == budget;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    systemPrompt,
    Object.hashAll(initialMessages),
    model,
    generation,
    Object.hashAll(enabledTools),
    policy,
    limits,
    liveness,
    noProgress,
    budget,
  );
}
