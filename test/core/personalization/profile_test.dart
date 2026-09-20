import 'package:domovoy/core/personalization/personalization.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AssistantProfile', () {
    test('defines persona and structured user preferences separately', () {
      final profile = AssistantProfile.create(
        id: ProfileId('developer'),
        name: 'Разработчик',
        nowMicros: 10,
        template: ProfileTemplate.expert,
      );

      expect(profile.soulMarkdown, contains('# Domovoy'));
      expect(profile.userMarkdown, contains('## STYLE'));
      expect(profile.userMarkdown, contains('## FORMAT'));
      expect(profile.userMarkdown, contains('## CONSTRAINTS'));
      expect(profile.userMarkdown, contains('## CONTEXT'));
      expect(profile.toJson(), containsPair('type', AssistantProfile.jsonType));
      expect(AssistantProfile.fromJson(profile.toJson()), profile);
    });

    test('rejects malformed USER.md and likely secrets', () {
      expect(
        () => normalizeUserMarkdown('## STYLE\n- short'),
        throwsA(isA<PersonalizationException>()),
      );
      expect(
        () => normalizeSoulMarkdown('token: sk-123456789012345678901234'),
        throwsA(isA<PersonalizationException>()),
      );
    });

    test('renders bounded profile blocks with escaped markup', () {
      final profile = AssistantProfile(
        id: ProfileId('escaped'),
        name: 'Escaped',
        revision: 0,
        soulMarkdown: 'Говори <кратко>.',
        userMarkdown: '''## STYLE
- concise
## FORMAT
- text
## CONSTRAINTS
- none
## CONTEXT
- test''',
        createdAtMicros: 1,
        updatedAtMicros: 1,
      );

      final rendered = renderPersonalizationPrompt(profile);
      expect(rendered, contains('<agent_persona source="SOUL.md">'));
      expect(rendered, contains('&lt;кратко&gt;'));
      expect(rendered, contains('<user_profile source="USER.md">'));
    });
  });
}
