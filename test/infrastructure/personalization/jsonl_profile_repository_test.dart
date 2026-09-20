import 'package:domovoy/core/llm/llm.dart';
import 'package:domovoy/core/personalization/personalization.dart';
import 'package:domovoy/infrastructure/personalization/personalization.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/memory_jsonl_storage.dart';

void main() {
  test('replays profile revisions, active selection, and deletion', () async {
    final storage = FakeMemoryJsonlStorage();
    final repository = JsonlProfileRepository(storage: storage);
    final cancellation = CancellationSource().token;
    final original = AssistantProfile.create(
      id: ProfileId('primary'),
      name: 'Primary',
      nowMicros: 1,
    );

    await repository.save(
      original,
      expectedRevision: 0,
      cancellation: cancellation,
    );
    final revised = original.revise(
      userMarkdown: expertUserMarkdown,
      updatedAtMicros: 2,
    );
    await repository.save(
      revised,
      expectedRevision: 0,
      cancellation: cancellation,
    );
    await repository.saveActive(
      ActiveProfileSelection(profileId: original.id, revision: 0),
      expectedRevision: 0,
      cancellation: cancellation,
    );

    expect(
      await repository.load(original.id, cancellation: cancellation),
      revised,
    );
    expect(
      (await repository.loadActive(cancellation: cancellation))?.profileId,
      original.id,
    );
    expect(await repository.list(cancellation: cancellation), [revised]);

    await repository.delete(
      original.id,
      expectedRevision: revised.revision,
      cancellation: cancellation,
    );
    expect(await repository.list(cancellation: cancellation), isEmpty);
  });

  test('ignores an incomplete final JSONL line', () async {
    final storage = FakeMemoryJsonlStorage();
    final repository = JsonlProfileRepository(storage: storage);
    final cancellation = CancellationSource().token;
    final profile = AssistantProfile.create(
      id: ProfileId('durable'),
      name: 'Durable',
      nowMicros: 1,
    );
    await repository.save(
      profile,
      expectedRevision: 0,
      cancellation: cancellation,
    );
    storage.appendText(
      const ProfileJsonlKeyCodec().profile(profile.id),
      '{partial',
    );

    expect(
      await repository.load(profile.id, cancellation: cancellation),
      profile,
    );
  });
}
