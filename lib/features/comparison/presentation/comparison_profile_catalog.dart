import 'package:flutter/foundation.dart';

import '../data/comparison_profile_store.dart';
import '../domain/chat_model_profile.dart';

final class ComparisonProfileCatalog extends ChangeNotifier {
  ComparisonProfileCatalog({required ComparisonProfileRepository repository})
    : _repository = repository;

  final ComparisonProfileRepository _repository;
  List<ChatModelProfile> _profiles = kDay5PresetProfiles;
  String? _warning;
  bool _disposed = false;

  List<ChatModelProfile> get profiles => _profiles;
  String? get warning => _warning;

  Future<void> load() async {
    final result = await _repository.load();
    _profiles = result.profiles;
    _warning = result.warning;
    _notify();
  }

  Future<void> save(List<ChatModelProfile> profiles) async {
    await _repository.save(profiles);
    _profiles = List<ChatModelProfile>.unmodifiable(profiles);
    _warning = null;
    _notify();
  }

  Future<void> saveOne(int index, ChatModelProfile profile) async {
    final next = [..._profiles];
    next[index] = profile;
    await save(next);
  }

  Future<void> reset() async {
    await _repository.reset();
    _profiles = kDay5PresetProfiles;
    _warning = null;
    _notify();
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
