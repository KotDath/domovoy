import '../../../core/personalization/personalization.dart';

enum ProfileStatus { loading, ready, failed }

final class ProfileState {
  ProfileState({
    required this.status,
    List<AssistantProfile> profiles = const <AssistantProfile>[],
    this.activeProfileId,
    this.activeSelectionRevision = 0,
    this.offerInterviewOnCreate = true,
    this.busy = false,
    this.error,
  }) : profiles = List<AssistantProfile>.unmodifiable(profiles);

  factory ProfileState.initial() => ProfileState(status: ProfileStatus.loading);

  final ProfileStatus status;
  final List<AssistantProfile> profiles;
  final ProfileId? activeProfileId;
  final int activeSelectionRevision;
  final bool offerInterviewOnCreate;
  final bool busy;
  final String? error;

  AssistantProfile? get activeProfile =>
      profiles.where((profile) => profile.id == activeProfileId).firstOrNull;

  ProfileState copyWith({
    ProfileStatus? status,
    List<AssistantProfile>? profiles,
    Object? activeProfileId = _keep,
    int? activeSelectionRevision,
    bool? offerInterviewOnCreate,
    bool? busy,
    Object? error = _keep,
  }) => ProfileState(
    status: status ?? this.status,
    profiles: profiles ?? this.profiles,
    activeProfileId: identical(activeProfileId, _keep)
        ? this.activeProfileId
        : activeProfileId as ProfileId?,
    activeSelectionRevision:
        activeSelectionRevision ?? this.activeSelectionRevision,
    offerInterviewOnCreate:
        offerInterviewOnCreate ?? this.offerInterviewOnCreate,
    busy: busy ?? this.busy,
    error: identical(error, _keep) ? this.error : error as String?,
  );

  static const _keep = Object();
}
