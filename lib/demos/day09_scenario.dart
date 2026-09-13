import 'dart:convert';

import 'package:flutter/services.dart';

final class Day09ScenarioStep {
  const Day09ScenarioStep({required this.title, required this.prompt});

  final String title;
  final String prompt;
}

Future<List<Day09ScenarioStep>> loadDay09Scenario() async {
  final raw = await rootBundle.loadString('assets/day09_scenario.json');
  final decoded = jsonDecode(raw);
  if (decoded is! List || decoded.length != 14) {
    throw const FormatException('Day 9 scenario must contain 14 steps.');
  }
  return List<Day09ScenarioStep>.unmodifiable(
    decoded.map((row) {
      if (row is! Map<String, dynamic> ||
          row['title'] is! String ||
          row['prompt'] is! String ||
          (row['title'] as String).trim().isEmpty ||
          (row['prompt'] as String).trim().isEmpty) {
        throw const FormatException('Day 9 scenario step is invalid.');
      }
      return Day09ScenarioStep(
        title: row['title'] as String,
        prompt: row['prompt'] as String,
      );
    }),
  );
}
