import '../llm/cancellation.dart';
import 'errors.dart';
import 'profile.dart';

abstract interface class ProfileRepository {
  Future<List<AssistantProfile>> list({
    required CancellationToken cancellation,
  });

  Future<AssistantProfile?> load(
    ProfileId id, {
    required CancellationToken cancellation,
  });

  Future<void> save(
    AssistantProfile profile, {
    required int expectedRevision,
    required CancellationToken cancellation,
  });

  Future<void> delete(
    ProfileId id, {
    required int expectedRevision,
    required CancellationToken cancellation,
  });
}

final class ActiveProfileSelection {
  const ActiveProfileSelection({
    required this.profileId,
    required this.revision,
  });

  final ProfileId profileId;
  final int revision;
}

abstract interface class ActiveProfileRepository {
  Future<ActiveProfileSelection?> loadActive({
    required CancellationToken cancellation,
  });

  Future<void> saveActive(
    ActiveProfileSelection selection, {
    required int expectedRevision,
    required CancellationToken cancellation,
  });
}

abstract interface class ProfilePreferenceRepository {
  Future<bool> loadOfferInterviewOnCreate();

  Future<void> saveOfferInterviewOnCreate(bool value);
}

/// Shared bootstrap boundary used by both UI and request-time resolution.
final class ProfileCatalogService {
  ProfileCatalogService({
    required this.profiles,
    required this.activeProfile,
    required this.nowMicros,
  });

  final ProfileRepository profiles;
  final ActiveProfileRepository activeProfile;
  final int Function() nowMicros;
  Future<AssistantProfile>? _ready;

  Future<AssistantProfile> ensureReady() => _ready ??= _initialize();

  Future<AssistantProfile> current() async {
    await ensureReady();
    final cancellation = CancellationSource().token;
    final selection = await activeProfile.loadActive(
      cancellation: cancellation,
    );
    if (selection == null) {
      throwPersonalization(
        PersonalizationErrorKind.persistence,
        'Активный профиль не настроен.',
      );
    }
    final profile = await profiles.load(
      selection.profileId,
      cancellation: cancellation,
    );
    if (profile == null) {
      throwPersonalization(
        PersonalizationErrorKind.persistence,
        'Активный профиль не найден.',
      );
    }
    return profile;
  }

  Future<AssistantProfile> _initialize() async {
    final cancellation = CancellationSource().token;
    final existing = await profiles.list(cancellation: cancellation);
    final active = await activeProfile.loadActive(cancellation: cancellation);
    if (active != null) {
      final selected = existing
          .where((profile) => profile.id == active.profileId)
          .firstOrNull;
      if (selected == null) {
        throwPersonalization(
          PersonalizationErrorKind.persistence,
          'Активный профиль ссылается на отсутствующую запись.',
        );
      }
      return selected;
    }
    final AssistantProfile selected;
    if (existing.isEmpty) {
      selected = AssistantProfile.create(
        id: ProfileId('default'),
        name: 'По умолчанию',
        nowMicros: nowMicros(),
      );
      await profiles.save(
        selected,
        expectedRevision: 0,
        cancellation: cancellation,
      );
    } else {
      selected = existing.first;
    }
    await activeProfile.saveActive(
      ActiveProfileSelection(profileId: selected.id, revision: 0),
      expectedRevision: 0,
      cancellation: cancellation,
    );
    return selected;
  }
}
