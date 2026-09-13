// Explicit paid test: flutter test tool/live_day10_memory_test.dart --reporter expanded
// DEEPSEEK_API_KEY stays in the environment; each step saves a local JSON record.
import 'dart:convert';
import 'dart:io';

import 'package:domovoy/app.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/demos/day10_engine.dart';
import 'package:domovoy/demos/day10_live_invoker.dart';
import 'package:domovoy/demos/demo_dependencies.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

final class _EvidenceStore implements Day10StateStore {
  _EvidenceStore(this.file);
  final File file;
  @override
  Future<String?> read() async =>
      await file.exists() ? file.readAsString() : null;
  @override
  Future<void> write(String data) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.next');
    await temporary.writeAsString(data);
    await temporary.rename(file.path);
  }

  @override
  Future<void> clear() async {
    if (await file.exists()) await file.delete();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  test(
    'Day 10 two-agent real DeepSeek scenario',
    () async {
      expect(
        Platform.environment['DEEPSEEK_API_KEY'],
        isNotNull,
        reason: 'Set DEEPSEEK_API_KEY for this explicit paid test.',
      );
      final client = http.Client();
      final stack = buildProductionAgentStack(
        httpClient: client,
        credentials: DefaultProviderCredentialResolver(
          store: MemoryProviderCredentialStore(),
          readEnvironment: (name) => Platform.environment[name],
        ),
        diagnosticNoCompaction: true,
      );
      final dependencies = DemoDependencies(stack: stack, client: client);
      final evidenceFile = File('/tmp/domovoy-evidence/day10-memory-live.json');
      final engine = Day10DemoEngine(
        prompts: Day10Prompt.parse(
          await rootBundle.loadString('assets/day10_scenario.json'),
        ),
        invoker: Day10LiveInvoker(dependencies),
        store: _EvidenceStore(evidenceFile),
      );
      try {
        await engine.initialize();
        await engine.reset();
        for (var i = 0; i < 14; i++) {
          await engine.runNextComparison();
          expect(
            engine.error,
            isNull,
            reason: 'Step ${i + 1}: ${engine.error}',
          );
          expect(engine.comparisonStep, i + 1);
        }
        await engine.runBranchPrompt('a');
        expect(engine.error, isNull);
        await engine.runBranchPrompt('b');
        expect(engine.error, isNull);
        await engine.runBranchCheck('a');
        expect(engine.error, isNull);
        await engine.runBranchCheck('b');
        expect(engine.error, isNull);
        for (final key in ['sliding', 'facts', 'branching', 'a', 'b']) {
          final branch = engine.branches[key]!;
          // One compact, machine-readable line per strategy; source of truth is
          // the saved JSON ledger, not these convenience totals.
          stdout.writeln(
            jsonEncode({
              'branch': key,
              'pairs': branch.pairs.length,
              'mainCalls': branch.invocations
                  .where((row) => row.role == 'main')
                  .length,
              'memoryCalls': branch.invocations
                  .where((row) => row.role == 'memory')
                  .length,
              'input': branch.newSpend.requestContext.value,
              'output': branch.newSpend.responseGenerated.value,
              'overall': branch.newSpend.overall.value,
              'answer': branch.pairs.last.assistant,
              if (key == 'facts')
                'facts': branch.facts.map((fact) => fact.toJson()).toList(),
            }),
          );
        }
      } finally {
        engine.dispose();
        await dependencies.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 30)),
  );
}
