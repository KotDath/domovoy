import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/infrastructure/mcp/servers/digest/digest.dart';
import 'package:flutter_test/flutter_test.dart';

import 'digest_test_support.dart';

DigestInvocationScope scopeFor({
  String requestId = '42',
  String? sessionId,
  String? taskId,
  Map<String, Object?>? meta,
}) {
  return DigestInvocationScope(
    requestId: requestId,
    sessionId: sessionId,
    taskId: taskId,
    meta: meta,
  );
}

void main() {
  group('DigestInvocationScope', () {
    test('requires a non-blank request id', () {
      expect(() => scopeFor(requestId: '  '), throwsA(isA<ArgumentError>()));
    });

    test('bounds and freezes the meta copy', () {
      final scope = scopeFor(
        meta: <String, Object?>{
          'run': 'run-a',
          'count': 3,
          'flag': true,
          'nothing': null,
          'nested': <String, Object?>{'ignored': true},
          'long': 'x' * 600,
          for (var i = 0; i < 40; i++) 'extra$i': i,
        },
      );

      expect(scope.meta['run'], 'run-a');
      expect(scope.meta['count'], 3);
      expect(scope.meta['flag'], isTrue);
      expect(scope.meta.containsKey('nothing'), isTrue);
      expect(scope.meta.containsKey('nested'), isFalse);
      expect((scope.meta['long']! as String).length, 512);
      expect(scope.meta.length, lessThanOrEqualTo(32));
      expect(() => scope.meta['run'] = 'mutated', throwsUnsupportedError);
    });
  });

  group('DigestModelPinRegistry', () {
    test('resolves only registered scopes and isolates concurrent runs', () {
      final registry = DigestModelPinRegistry(
        scopeKeyOf: (scope) => scope.meta['run'] as String?,
      );
      registry.registerScope('run-a', digestModelA);
      registry.registerScope('run-b', digestModelB);
      expect(registry.activeScopeCount, 2);

      expect(
        registry.resolve(scopeFor(meta: {'run': 'run-a'}))!.model,
        digestModelA,
      );
      expect(
        registry.resolve(scopeFor(meta: {'run': 'run-b'}))!.model,
        digestModelB,
      );
      expect(registry.resolve(scopeFor(meta: {'run': 'run-c'})), isNull);
      expect(registry.resolve(scopeFor()), isNull);
    });

    test('releasing a run removes only that pin', () {
      final registry = DigestModelPinRegistry(
        scopeKeyOf: (scope) => scope.requestId,
      );
      registry.registerScope('1', digestModelA);
      registry.registerScope('2', digestModelB);

      registry.releaseScope('1');

      expect(registry.resolve(scopeFor(requestId: '1')), isNull);
      expect(registry.resolve(scopeFor(requestId: '2'))!.model, digestModelB);
      registry.clear();
      expect(registry.activeScopeCount, 0);
    });

    test('re-registering a scope replaces the pin', () {
      final registry = DigestModelPinRegistry(
        scopeKeyOf: (scope) => scope.requestId,
      );
      registry.registerScope('1', digestModelA);
      registry.registerScope('1', digestModelB);

      expect(registry.resolve(scopeFor(requestId: '1'))!.model, digestModelB);
    });

    test('rejects a blank scope key', () {
      final registry = DigestModelPinRegistry(
        scopeKeyOf: (scope) => scope.requestId,
      );
      expect(
        () => registry.registerScope('   ', digestModelA),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('an extractor that returns null never falls back to a default', () {
      final registry = DigestModelPinRegistry(scopeKeyOf: (scope) => null);
      registry.registerScope('run-a', digestModelA);
      expect(registry.resolve(scopeFor()), isNull);
      expect(registry.activeScopeCount, 1);
    });
  });

  group('UnavailableDigestModelPinResolver', () {
    test('never returns a pin', () {
      const resolver = UnavailableDigestModelPinResolver();
      expect(resolver.resolve(scopeFor()), isNull);
    });
  });

  group('DigestModelPin', () {
    test('keeps the model ref it was created with', () {
      final pin = DigestModelPin(model: digestModelA);
      expect(pin.model, digestModelA);
      expect(
        pin,
        DigestModelPin(
          model: ModelRef(
            providerId: BuiltInLlmCatalog.deepSeek,
            modelId: BuiltInLlmCatalog.deepSeekV4Flash,
          ),
        ),
      );
    });
  });
}
