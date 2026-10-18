import 'dart:io';
import 'package:domovoy/core/agents/agents.dart';
import 'package:domovoy/core/support/support.dart';
import 'package:domovoy/features/support/application/support_catalog.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl_stream_storage.dart';
import 'package:domovoy/infrastructure/agents/jsonl/jsonl_filesystem_storage_io.dart';
import 'package:domovoy/infrastructure/support/jsonl_support_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/memory_jsonl_storage.dart';
import '../../support/support_harness.dart';

void main() {
  test(
    'fresh native storage replays owner, ticket, explicit snapshot and resolved/reopen revisions after runtime close',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'support-replay-',
      );
      addTearDown(() => directory.delete(recursive: true));
      JsonlStreamStorage storage() => JsonlFilesystemStreamStorage(
        applicationSupportDirectoryResolver: () async => directory,
        namespaceDirectoryName: 'product-support-test',
      );
      final repo = JsonlSupportRepository(storage());
      final owner = await repo.owner();
      final id = newSupportId();
      final ticket = SupportTicket(
        id: id,
        ownerId: owner,
        subject: 'Тема',
        description: 'Описание',
        sessionId: AgentSessionId('$supportSessionPrefix$id'),
        createdAt: 10,
        updatedAt: 10,
        snapshot: supportSnapshot,
      );
      await repo.save(ticket, expectedRevision: null);
      await repo.save(
        ticket.update(status: SupportStatus.resolved),
        expectedRevision: 0,
      );
      final second = JsonlSupportRepository(storage());
      expect(await second.owner(), owner);
      final reopened = (await second.load(
        id,
      ))!.update(status: SupportStatus.open);
      await second.save(reopened, expectedRevision: 1);
      final third = JsonlSupportRepository(storage());
      expect((await third.load(id))!.status, SupportStatus.open);
      expect((await third.load(id))!.revision, 2);
      expect(
        (await third.load(id))!.snapshot.toJson(),
        supportSnapshot.toJson(),
      );
      await expectLater(
        third.save(reopened, expectedRevision: 1),
        throwsStateError,
      );
    },
  );

  test(
    'pending linkage survives failed ready publication and recovers exactly one session',
    () async {
      final storage = _FailingStorage();
      final sessions = FakeMemoryJsonlStorage();
      final h = SupportHarness(
        ticketStorage: storage,
        sessionStorage: sessions,
        withMcp: false,
      );
      // owner, intent, then fail activation after the session has been saved.
      storage.failAt = 3;
      await expectLater(h.create(), throwsStateError);
      final pending = (await h.tickets.list()).single;
      expect(pending.ready, false);
      expect(await h.sessions.load(pending.sessionId), isNotNull);
      expect(
        (await SupportSessionCatalog(h.sessions).list()).available,
        isEmpty,
      );
      await h.close();
      final fresh = SupportHarness(
        ticketStorage: storage,
        sessionStorage: sessions,
        withMcp: false,
      );
      addTearDown(fresh.close);
      final ready = await fresh.service.recover(pending);
      expect(ready.ready, true);
      expect((await fresh.sessions.list()).available, hasLength(1));
      expect((await fresh.tickets.list()).single.sessionId, pending.sessionId);
      expect((await fresh.service.recover(pending)).revision, ready.revision);
    },
  );

  test(
    'failed initial session persistence leaves a recoverable intent, not a ready ticket',
    () async {
      final sessions = _FailingStorage()..failAt = 1;
      final h = SupportHarness(sessionStorage: sessions, withMcp: false);
      addTearDown(h.close);
      await expectLater(h.create(), throwsA(isA<Object>()));
      final intent = (await h.tickets.list()).single;
      expect(intent.ready, false);
      expect((await h.sessions.list()).available, isEmpty);
      final recovered = await h.service.recover(intent);
      expect(recovered.ready, true);
      expect((await h.sessions.list()).available.single.id, intent.sessionId);
    },
  );

  test(
    'native session and ticket survive full runtime close and brand new storage objects',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'support-full-replay-',
      );
      addTearDown(() => directory.delete(recursive: true));
      JsonlStreamStorage storage(String name) => JsonlFilesystemStreamStorage(
        applicationSupportDirectoryResolver: () async => directory,
        namespaceDirectoryName: name,
      );
      final first = SupportHarness(
        ticketStorage: storage('support-test'),
        sessionStorage: storage('support-sessions-test'),
        withMcp: false,
      );
      final ticket = await first.create();
      final owner = await first.tickets.owner();
      await first.close();
      final second = SupportHarness(
        ticketStorage: storage('support-test'),
        sessionStorage: storage('support-sessions-test'),
        withMcp: false,
      );
      addTearDown(second.close);
      await second.controller.initialize();
      await second.controller.select((await second.tickets.load(ticket.id))!);
      expect(second.controller.selected!.sessionId, ticket.sessionId);
      expect(second.chat.state.selectedId, ticket.sessionId);
      expect(await second.tickets.owner(), owner);
      expect(
        (await second.sessions.load(ticket.sessionId))!.definition.enabledTools,
        isEmpty,
      );
      expect(
        (await SupportSessionCatalog(second.sessions).list()).available,
        isEmpty,
      );
    },
  );

  test('corrupt or truncated support journal fails closed', () async {
    final storage = FakeMemoryJsonlStorage();
    final repo = JsonlSupportRepository(storage);
    await repo.owner();
    storage.appendText('support', '{"version":1');
    await expectLater(
      JsonlSupportRepository(storage).list(),
      throwsFormatException,
    );
  });

  test(
    'reserved support sessions cannot be restored by a normal chat controller',
    () async {
      final h = SupportHarness(withMcp: false);
      addTearDown(h.close);
      final ticket = await h.create();
      final normal = SupportHarness(withMcp: false);
      addTearDown(normal.close);
      // The guard runs before loading or upgrading any legacy definition.
      expect(
        (await normal.chat.restoreChat(
          AgentSessionId('normal-chat'),
        )).isSuccess,
        false,
      );
      final catalog = await SupportSessionCatalog(h.sessions).list();
      expect(catalog.available, isEmpty);
      expect(ticket.sessionId.value, startsWith(supportSessionPrefix));
    },
  );
}

final class _FailingStorage implements JsonlGuardedStreamStorage {
  final delegate = FakeMemoryJsonlStorage();
  @override
  Future<List<String>> listKeys() => delegate.listKeys();
  @override
  Future<Stream<List<int>>?> read(String key) => delegate.read(key);
  @override
  Future<void> cleanup(String key) => delegate.cleanup(key);
  int writes = 0;
  int failAt = -1;
  @override
  Future<void> publish(String key, List<int> contents) async {
    if (++writes == failAt) throw StateError('injected publication failure');
    await delegate.publish(key, contents);
  }

  @override
  Future<void> publishGuarded(
    String key,
    List<int> contents, {
    required void Function() beforeCommit,
  }) async {
    if (++writes == failAt) throw StateError('injected session failure');
    await delegate.publishGuarded(key, contents, beforeCommit: beforeCommit);
  }
}
