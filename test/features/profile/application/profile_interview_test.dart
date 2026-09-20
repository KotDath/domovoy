import 'package:domovoy/core/personalization/personalization.dart';
import 'package:domovoy/features/profile/application/profile_interview.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('collects five answers and validates the generated USER.md', () async {
    final llm = _FakeInterviewLlm();
    final controller = ProfileInterviewController(llm: llm);

    await controller.start();
    expect(controller.stage, ProfileInterviewStage.awaitingAnswer);
    for (
      var index = 0;
      index < ProfileInterviewController.topics.length;
      index++
    ) {
      await controller.submit('answer $index');
    }

    expect(controller.stage, ProfileInterviewStage.preview);
    expect(controller.answers, hasLength(5));
    expect(controller.draft, defaultUserMarkdown.trim());
    expect(llm.draftCalls, 1);
    controller.dispose();
  });

  test('does not expose a malformed model draft for confirmation', () async {
    final controller = ProfileInterviewController(
      llm: _FakeInterviewLlm(draftText: 'bad'),
    );
    await controller.start();
    for (
      var index = 0;
      index < ProfileInterviewController.topics.length;
      index++
    ) {
      await controller.submit('answer');
    }

    expect(controller.stage, ProfileInterviewStage.failed);
    expect(controller.draft, isNull);
    controller.dispose();
  });
}

final class _FakeInterviewLlm implements ProfileInterviewLlm {
  _FakeInterviewLlm({this.draftText = defaultUserMarkdown});

  final String draftText;
  var draftCalls = 0;

  @override
  Future<String> ask(
    ProfileInterviewTopic topic,
    List<ProfileInterviewAnswer> answers,
  ) async => 'Question for ${topic.name}?';

  @override
  Future<String> draft(List<ProfileInterviewAnswer> answers) async {
    draftCalls += 1;
    return draftText;
  }
}
