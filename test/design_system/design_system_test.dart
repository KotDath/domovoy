import 'dart:io';

import 'package:domovoy/design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('responsive workspace policy', () {
    test('uses the centralized desktop boundary and dimensions', () {
      final below = resolveWorkspaceLayout(
        const Size(DomovoyDimensions.desktopBreakpoint - 1, 800),
        1,
      );
      final at = resolveWorkspaceLayout(
        const Size(DomovoyDimensions.desktopBreakpoint, 800),
        1,
      );

      expect(below.kind, WorkspaceLayoutKind.narrow);
      expect(below.useSheets, isTrue);
      expect(at.kind, WorkspaceLayoutKind.desktop);
      expect(at.sidebarWidth, DomovoyDimensions.sidebarWidth);
      expect(at.timelineMaxWidth, DomovoyDimensions.timelineMaxWidth);
      expect(DomovoyDimensions.minimumTarget, greaterThanOrEqualTo(44));
    });

    test('large text selects the no-clipping narrow policy', () {
      final spec = resolveWorkspaceLayout(
        const Size(DomovoyDimensions.desktopBreakpoint + 200, 800),
        2,
      );

      expect(spec.kind, WorkspaceLayoutKind.narrow);
      expect(spec.contentInsets, DomovoyDimensions.compactPageInsets);
      expect(spec.useSheets, isTrue);
    });
  });

  group('semantic themes', () {
    test('dark and light expose complete distinct semantic roles', () {
      final dark = DomovoyTheme.dark().extension<DomovoyThemeTokens>()!;
      final light = DomovoyTheme.light().extension<DomovoyThemeTokens>()!;

      expect(dark.canvas, isNot(dark.surface));
      expect(dark.sidebar, isNot(dark.selectedSurface));
      expect(light.canvas, isNot(light.surface));
      expect(light.accent, isNot(dark.accent));
      expect(dark.fastMotion, lessThan(dark.normalMotion));
      expect(dark.focusStrokeWidth, greaterThanOrEqualTo(2));
      expect(
        _contrast(dark.textPrimary, dark.canvas),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(dark.textSecondary, dark.sidebar),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(light.textPrimary, light.canvas),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        _contrast(light.textSecondary, light.sidebar),
        greaterThanOrEqualTo(4.5),
      );
    });

    testWidgets('theme interpolation and reduced motion are deterministic', (
      tester,
    ) async {
      final dark = DomovoyTheme.dark().extension<DomovoyThemeTokens>()!;
      final light = DomovoyTheme.light().extension<DomovoyThemeTokens>()!;
      final middle = dark.lerp(light, 0.5);
      expect(middle.canvas, isNot(dark.canvas));
      expect(middle.canvas, isNot(light.canvas));

      Duration? resolved;
      await tester.pumpWidget(
        MaterialApp(
          theme: DomovoyTheme.dark(),
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Builder(
              builder: (context) {
                resolved = context.domovoyMotion(dark.normalMotion);
                return const SizedBox();
              },
            ),
          ),
        ),
      );
      expect(resolved, Duration.zero);
    });
  });

  testWidgets('semantic icon action meets the minimum target', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: DomovoyTheme.dark(),
        home: Scaffold(
          body: DomovoyIconAction(
            icon: Icons.settings,
            label: 'Settings',
            onPressed: () {},
          ),
        ),
      ),
    );

    final size = tester.getSize(find.byType(IconButton));
    expect(size.width, greaterThanOrEqualTo(DomovoyDimensions.minimumTarget));
    expect(size.height, greaterThanOrEqualTo(DomovoyDimensions.minimumTarget));
  });

  test('production presentation contains no raw visual constants', () {
    final paths = <String>[
      'lib/app.dart',
      'lib/features/settings/presentation/api_key_settings_dialog.dart',
      ...Directory(
        'lib/features/chat/presentation',
      ).listSync().whereType<File>().map((file) => file.path),
    ];
    final forbidden = <RegExp>[
      RegExp(r'\bColors\.'),
      RegExp(r'\bColor\s*\(\s*0x'),
      RegExp(r'BorderRadius\.circular\(\s*\d'),
      RegExp(r'EdgeInsets\.(?:all|symmetric|only|fromLTRB)\(\s*\d'),
      RegExp(r'(?:width|height|maxWidth|minHeight)\s*:\s*(?:276|900|960)'),
    ];

    for (final path in paths) {
      final source = File(path).readAsStringSync();
      for (final pattern in forbidden) {
        expect(source, isNot(matches(pattern)), reason: '$path: $pattern');
      }
    }
  });
}

double _contrast(Color a, Color b) {
  final lighter = a.computeLuminance() > b.computeLuminance() ? a : b;
  final darker = identical(lighter, a) ? b : a;
  return (lighter.computeLuminance() + 0.05) /
      (darker.computeLuminance() + 0.05);
}
