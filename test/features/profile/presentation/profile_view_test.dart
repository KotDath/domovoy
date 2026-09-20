import 'package:domovoy/core/personalization/personalization.dart';
import 'package:domovoy/design_system/design_system.dart';
import 'package:domovoy/features/profile/application/profile_controller.dart';
import 'package:domovoy/features/profile/presentation/profile_view.dart';
import 'package:domovoy/infrastructure/personalization/personalization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/memory_jsonl_storage.dart';

void main() {
  testWidgets('creates, edits, and activates a second profile', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = JsonlProfileRepository(
      storage: FakeMemoryJsonlStorage(),
    );
    var now = 10;
    final controller = ProfileController(
      profiles: repository,
      activeProfile: repository,
      catalog: ProfileCatalogService(
        profiles: repository,
        activeProfile: repository,
        nowMicros: () => now++,
      ),
      nowMicros: () => now++,
      preferences: _Preferences(),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: DomovoyTheme.light(),
        home: Scaffold(body: ProfileView(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('По умолчанию'), findsWidgets);
    expect(find.text('Сохранено: ревизия 0.'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('profile-create')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('new-profile-name')),
      'Эксперт',
    );
    await tester.pump();
    await tester.tap(find.text('Создать'));
    await tester.pumpAndSettle();

    expect(find.text('Эксперт'), findsWidgets);
    await tester.tap(find.text('Сделать активным'));
    await tester.pumpAndSettle();
    expect(controller.state.activeProfile?.name, 'Эксперт');

    await tester.enterText(
      find.byKey(const ValueKey('profile-editor:user')),
      expertUserMarkdown,
    );
    await tester.pump();
    expect(find.text('Есть несохранённые изменения.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('profile-save')));
    await tester.pumpAndSettle();
    expect(
      controller.state.activeProfile?.userMarkdown,
      expertUserMarkdown.trim(),
    );
    expect(find.text('Сохранено: ревизия 1.'), findsOneWidget);
    expect(find.textContaining('Профиль сохранён.'), findsOneWidget);
  });
}

final class _Preferences implements ProfilePreferenceRepository {
  var value = false;

  @override
  Future<bool> loadOfferInterviewOnCreate() async => value;

  @override
  Future<void> saveOfferInterviewOnCreate(bool value) async {
    this.value = value;
  }
}
