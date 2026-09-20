import 'package:flutter/foundation.dart';

import '../../../core/llm/cancellation.dart';
import '../../../core/personalization/personalization.dart';
import 'profile_state.dart';

final class ProfileController extends ChangeNotifier {
  ProfileController({
    required this.profiles,
    required this.activeProfile,
    required this.catalog,
    required this.nowMicros,
    this.preferences,
  });

  final ProfileRepository profiles;
  final ActiveProfileRepository activeProfile;
  final ProfileCatalogService catalog;
  final int Function() nowMicros;
  final ProfilePreferenceRepository? preferences;
  ProfileState _state = ProfileState.initial();
  bool _disposed = false;

  ProfileState get state => _state;

  Future<void> initialize() async {
    if (_disposed) return;
    try {
      await catalog.ensureReady();
      final offerInterview =
          await preferences?.loadOfferInterviewOnCreate() ?? true;
      await _reload(offerInterviewOnCreate: offerInterview);
    } on Object catch (error) {
      _set(
        _state.copyWith(
          status: ProfileStatus.failed,
          busy: false,
          error: _message(error),
        ),
      );
    }
  }

  Future<AssistantProfile?> create({
    required String name,
    ProfileTemplate template = ProfileTemplate.blank,
    String? userMarkdown,
  }) => _mutate(() async {
    final now = nowMicros();
    var profile = AssistantProfile.create(
      id: _newId(name, now),
      name: name,
      nowMicros: now,
      template: template,
    );
    if (userMarkdown != null) {
      profile = AssistantProfile(
        id: profile.id,
        name: profile.name,
        revision: profile.revision,
        soulMarkdown: profile.soulMarkdown,
        userMarkdown: userMarkdown,
        createdAtMicros: profile.createdAtMicros,
        updatedAtMicros: profile.updatedAtMicros,
      );
    }
    await profiles.save(
      profile,
      expectedRevision: 0,
      cancellation: CancellationSource().token,
    );
    await _reload();
    return profile;
  });

  Future<AssistantProfile?> clone(
    AssistantProfile source, {
    required String name,
  }) => _mutate(() async {
    final now = nowMicros();
    final profile = source.cloneAs(
      id: _newId(name, now),
      name: name,
      nowMicros: now,
    );
    await profiles.save(
      profile,
      expectedRevision: 0,
      cancellation: CancellationSource().token,
    );
    await _reload();
    return profile;
  });

  Future<AssistantProfile?> update(
    AssistantProfile profile, {
    String? name,
    String? soulMarkdown,
    String? userMarkdown,
  }) => _mutate(() async {
    final revised = profile.revise(
      name: name,
      soulMarkdown: soulMarkdown,
      userMarkdown: userMarkdown,
      updatedAtMicros: nowMicros(),
    );
    await profiles.save(
      revised,
      expectedRevision: profile.revision,
      cancellation: CancellationSource().token,
    );
    await _reload();
    return revised;
  });

  Future<bool> activate(AssistantProfile profile) async {
    final result = await _mutate(() async {
      final current = await activeProfile.loadActive(
        cancellation: CancellationSource().token,
      );
      if (current?.profileId == profile.id) return true;
      await activeProfile.saveActive(
        ActiveProfileSelection(
          profileId: profile.id,
          revision: current == null ? 0 : current.revision + 1,
        ),
        expectedRevision: current?.revision ?? 0,
        cancellation: CancellationSource().token,
      );
      await _reload();
      return true;
    });
    return result ?? false;
  }

  Future<bool> delete(AssistantProfile profile) async {
    if (_state.profiles.length <= 1 || _state.activeProfileId == profile.id) {
      _set(
        _state.copyWith(
          error: 'Активный или последний профиль удалить нельзя.',
        ),
      );
      return false;
    }
    final result = await _mutate(() async {
      await profiles.delete(
        profile.id,
        expectedRevision: profile.revision,
        cancellation: CancellationSource().token,
      );
      await _reload();
      return true;
    });
    return result ?? false;
  }

  Future<void> setOfferInterviewOnCreate(bool value) async {
    if (_disposed || _state.busy) return;
    final previous = _state.offerInterviewOnCreate;
    _set(_state.copyWith(offerInterviewOnCreate: value, error: null));
    try {
      await preferences?.saveOfferInterviewOnCreate(value);
    } on Object catch (error) {
      _set(
        _state.copyWith(
          offerInterviewOnCreate: previous,
          error: _message(error),
        ),
      );
    }
  }

  Future<T?> _mutate<T>(Future<T> Function() action) async {
    if (_disposed || _state.busy) return null;
    _set(_state.copyWith(busy: true, error: null));
    try {
      return await action();
    } on Object catch (error) {
      _set(_state.copyWith(busy: false, error: _message(error)));
      return null;
    } finally {
      if (!_disposed && _state.busy) _set(_state.copyWith(busy: false));
    }
  }

  Future<void> _reload({bool? offerInterviewOnCreate}) async {
    final cancellation = CancellationSource().token;
    final listed = await profiles.list(cancellation: cancellation);
    final selection = await activeProfile.loadActive(
      cancellation: cancellation,
    );
    _set(
      ProfileState(
        status: ProfileStatus.ready,
        profiles: listed,
        activeProfileId: selection?.profileId,
        activeSelectionRevision: selection?.revision ?? 0,
        offerInterviewOnCreate:
            offerInterviewOnCreate ?? _state.offerInterviewOnCreate,
      ),
    );
  }

  ProfileId _newId(String name, int now) {
    final base = name
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final prefix = base.isEmpty
        ? 'profile'
        : base.substring(0, base.length > 40 ? 40 : base.length);
    return ProfileId('$prefix-${now.toRadixString(36)}');
  }

  String _message(Object error) {
    if (error is PersonalizationException) return error.error.message;
    return 'Не удалось изменить профиль.';
  }

  void _set(ProfileState value) {
    _state = value;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
