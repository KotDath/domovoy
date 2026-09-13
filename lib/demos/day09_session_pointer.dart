import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/agents/ids.dart';

final class Day09PairIds {
  const Day09PairIds({required this.baseline, required this.summarized});

  final AgentSessionId baseline;
  final AgentSessionId summarized;

  static int _serial = 0;

  factory Day09PairIds.fresh() {
    final suffix =
        '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${++_serial}';
    return Day09PairIds(
      baseline: AgentSessionId('day09-baseline-$suffix'),
      summarized: AgentSessionId('day09-summary-$suffix'),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'version': 1,
    'baseline': baseline.value,
    'summarized': summarized.value,
  };

  static Day09PairIds? fromJson(Object? source) {
    if (source is! Map<String, dynamic> || source['version'] != 1) return null;
    final baseline = source['baseline'];
    final summarized = source['summarized'];
    if (baseline is! String ||
        summarized is! String ||
        !RegExp(r'^day09-baseline-[a-z0-9-]+$').hasMatch(baseline) ||
        !RegExp(r'^day09-summary-[a-z0-9-]+$').hasMatch(summarized)) {
      return null;
    }
    return Day09PairIds(
      baseline: AgentSessionId(baseline),
      summarized: AgentSessionId(summarized),
    );
  }
}

abstract interface class Day09PairPointerStore {
  Future<Day09PairIds?> read();
  Future<void> write(Day09PairIds ids);
}

final class SharedPreferencesDay09PairPointerStore
    implements Day09PairPointerStore {
  SharedPreferencesDay09PairPointerStore([SharedPreferencesAsync? preferences])
    : _preferences = preferences ?? SharedPreferencesAsync();

  static const key = 'domovoy.day09.active_pair.v1';
  final SharedPreferencesAsync _preferences;

  @override
  Future<Day09PairIds?> read() async {
    final raw = await _preferences.getString(key);
    if (raw == null) return null;
    try {
      return Day09PairIds.fromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> write(Day09PairIds ids) =>
      _preferences.setString(key, jsonEncode(ids.toJson()));
}
