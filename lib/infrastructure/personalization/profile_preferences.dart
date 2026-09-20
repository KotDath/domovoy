import 'package:shared_preferences/shared_preferences.dart';

import '../../core/personalization/repository.dart';

final class SharedPreferencesProfilePreferenceRepository
    implements ProfilePreferenceRepository {
  SharedPreferencesProfilePreferenceRepository([SharedPreferencesAsync? store])
    : _store = store ?? SharedPreferencesAsync();

  static const _offerInterviewKey =
      'ru.kotdath.domovoy.personalization.offer_interview_on_create';

  final SharedPreferencesAsync _store;

  @override
  Future<bool> loadOfferInterviewOnCreate() async =>
      await _store.getBool(_offerInterviewKey) ?? true;

  @override
  Future<void> saveOfferInterviewOnCreate(bool value) =>
      _store.setBool(_offerInterviewKey, value);
}
