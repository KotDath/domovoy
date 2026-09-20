import '../agents/dynamic_context.dart';
import 'profile.dart';
import 'render.dart';
import 'repository.dart';

final class ProfileContextTrace {
  const ProfileContextTrace({
    required this.profileId,
    required this.profileName,
    required this.profileRevision,
    required this.renderedCharacters,
  });

  final ProfileId profileId;
  final String profileName;
  final int profileRevision;
  final int renderedCharacters;
}

final class PersonalizationDynamicContextProvider
    implements AgentDynamicContextProvider {
  PersonalizationDynamicContextProvider({required this.catalog});

  final ProfileCatalogService catalog;

  @override
  Future<AgentDynamicContext?> provide(
    AgentDynamicContextRequest request,
  ) async {
    final profile = await catalog.current();
    final rendered = renderPersonalizationPrompt(profile);
    return AgentDynamicContext(
      systemPromptText: rendered,
      audit: ProfileContextTrace(
        profileId: profile.id,
        profileName: profile.name,
        profileRevision: profile.revision,
        renderedCharacters: rendered.runes.length,
      ),
    );
  }
}
