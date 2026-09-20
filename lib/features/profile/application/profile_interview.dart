import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/agents/agents.dart';
import '../../../core/personalization/personalization.dart';

enum ProfileInterviewStage {
  idle,
  asking,
  awaitingAnswer,
  generating,
  preview,
  failed,
}

enum ProfileInterviewTopic { role, style, format, constraints, context }

final class ProfileInterviewAnswer {
  const ProfileInterviewAnswer({required this.topic, required this.answer});

  final ProfileInterviewTopic topic;
  final String answer;
}

abstract interface class ProfileInterviewLlm {
  Future<String> ask(
    ProfileInterviewTopic topic,
    List<ProfileInterviewAnswer> answers,
  );

  Future<String> draft(List<ProfileInterviewAnswer> answers);
}

final class AgentProfileInterviewLlm implements ProfileInterviewLlm {
  AgentProfileInterviewLlm({required this.runtime, required this.definition});

  final AgentRuntime runtime;
  final AgentDefinition definition;

  static const instruction =
      '''Ты проводишь короткое интервью для настройки USER.md персонального ассистента.
Не проси секреты, медицинские, финансовые или иные чувствительные данные. Не используй инструменты.
Для вопроса верни только один короткий вопрос по заданной теме, учитывая предыдущие ответы.
Для черновика верни только Markdown с точными разделами ## STYLE, ## FORMAT, ## CONSTRAINTS, ## CONTEXT.
Пиши компактные декларативные пункты. Не добавляй сведения, которых пользователь не сообщал.''';

  static AgentDefinition definitionFrom(AgentDefinition base) =>
      AgentDefinition(
        id: AgentId('profile-interview'),
        name: 'Profile interview',
        systemPrompt: instruction,
        model: base.model,
        generation: base.generation,
        enabledTools: const <ToolId>[],
        policy: PolicyId('deny'),
        limits: AgentRunLimits(maxModelTurns: 1, maxToolCalls: 0),
      );

  @override
  Future<String> ask(
    ProfileInterviewTopic topic,
    List<ProfileInterviewAnswer> answers,
  ) => _run('''Сформулируй один вопрос для этапа ${topic.name}.
Предыдущие ответы:
${_answers(answers)}''');

  @override
  Future<String> draft(List<ProfileInterviewAnswer> answers) =>
      _run('''Создай итоговый USER.md.
Ответы пользователя:
${_answers(answers)}''');

  Future<String> _run(String input) async {
    final run = runtime.agent(definition).run(input);
    final buffer = StringBuffer();
    await for (final event in run.events) {
      if (event is AgentAnswerDelta) buffer.write(event.text);
      if (event is AgentRunFailed) {
        throw StateError(event.error.message);
      }
      if (event is AgentRunCancelled || event is AgentRunStopped) {
        throw StateError('Интервью было прервано.');
      }
    }
    final text = buffer.toString().trim();
    if (text.isEmpty) throw StateError('Модель вернула пустой ответ.');
    return text;
  }

  String _answers(List<ProfileInterviewAnswer> answers) => answers.isEmpty
      ? 'Пока нет.'
      : answers
            .map((answer) => '${answer.topic.name}: ${answer.answer}')
            .join('\n');
}

final class ProfileInterviewController extends ChangeNotifier {
  ProfileInterviewController({required this.llm});

  final ProfileInterviewLlm llm;
  ProfileInterviewStage stage = ProfileInterviewStage.idle;
  int topicIndex = 0;
  String? question;
  String? draft;
  String? error;
  final List<ProfileInterviewAnswer> answers = <ProfileInterviewAnswer>[];
  bool _disposed = false;

  static const topics = ProfileInterviewTopic.values;

  Future<void> start() async {
    answers.clear();
    topicIndex = 0;
    draft = null;
    error = null;
    await _ask();
  }

  Future<void> submit(String answer) async {
    if (stage != ProfileInterviewStage.awaitingAnswer) return;
    final normalized = answer.trim();
    if (normalized.isEmpty) return;
    answers.add(
      ProfileInterviewAnswer(topic: topics[topicIndex], answer: normalized),
    );
    if (topicIndex == topics.length - 1) {
      await generate();
      return;
    }
    topicIndex += 1;
    await _ask();
  }

  Future<void> skip() => submit('Не указано.');

  Future<void> back() async {
    if (answers.isEmpty || stage == ProfileInterviewStage.generating) return;
    answers.removeLast();
    topicIndex = answers.length.clamp(0, topics.length - 1);
    await _ask();
  }

  Future<void> generate() async {
    _set(ProfileInterviewStage.generating);
    try {
      final value = normalizeUserMarkdown(
        await llm.draft(List.unmodifiable(answers)),
      );
      draft = value;
      _set(ProfileInterviewStage.preview);
    } on Object catch (failure) {
      error = failure is PersonalizationException
          ? failure.error.message
          : 'Не удалось подготовить USER.md.';
      _set(ProfileInterviewStage.failed);
    }
  }

  void cancel() {
    answers.clear();
    question = null;
    draft = null;
    error = null;
    topicIndex = 0;
    _set(ProfileInterviewStage.idle);
  }

  Future<void> _ask() async {
    _set(ProfileInterviewStage.asking);
    try {
      question = await llm.ask(topics[topicIndex], List.unmodifiable(answers));
      _set(ProfileInterviewStage.awaitingAnswer);
    } on Object {
      error = 'Не удалось продолжить интервью.';
      _set(ProfileInterviewStage.failed);
    }
  }

  void _set(ProfileInterviewStage value) {
    stage = value;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
