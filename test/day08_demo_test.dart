import 'package:domovoy/app.dart';
import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/day08_main.dart';
import 'package:domovoy/demos/demo_dependencies.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // ignore: invalid_use_of_visible_for_testing_member
  SharedPreferences.setMockInitialValues(<String, Object>{});

  testWidgets(
    'overflow demo sends once and shows raw safe API error without usage',
    (tester) async {
      var posts = 0;
      final client = MockClient((request) async {
        if (request.method == 'POST') {
          posts++;
          expect(request.url.path, '/chat/completions');
          expect(request.body.length, greaterThan(2000));
          expect(request.body, contains('"max_tokens":1'));
          return http.Response(
            '{"error":{"type":"invalid_request_error","code":"invalid_request_error","message":"This model\'s maximum context length is 1048576 tokens. However, you requested 1100005 tokens (1100004 in the messages, 1 in the completion). Please reduce the length of the messages or completion."}}',
            400,
          );
        }
        return http.Response('{}', 404);
      });
      final stack = buildProductionAgentStack(
        httpClient: client,
        credentials: DefaultProviderCredentialResolver(
          store: MemoryProviderCredentialStore(<ProviderId, String>{
            BuiltInLlmCatalog.deepSeek: 'test-key',
          }),
          readEnvironment: (_) => null,
        ),
        diagnosticNoCompaction: true,
      );
      expect(stack.runtime.historyCompactor, isNull);
      expect(stack.runtime.compactionTrigger, isNull);
      await tester.pumpWidget(
        Day08DemoApp(
          dependencies: DemoDependencies(stack: stack, client: client),
          overflowUnitCount: 1000,
        ),
      );
      await tester.tap(find.byKey(const ValueKey('day08-overflow')));
      await tester.pump();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 1)),
      );
      await tester.pump();
      expect(posts, 1);
      expect(
        find.textContaining('maximum context length is 1048576'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('day08-error')), findsOneWidget);
      expect(find.text('—'), findsWidgets);
      expect(find.text('История: ввод — · вывод — · всего —'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
