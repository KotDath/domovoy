import 'dart:convert';
import 'dart:io';
import 'package:domovoy/infrastructure/support/support_manual.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'authoritative bundled manual integrity/provenance/package version matches repository source',
    () async {
      final manual = await BundledSupportManual.load(
        read: (p) => File(p).readAsString(),
      );
      expect(manual.documents.length, 6);
      expect(manual.documents.map((d) => d.source).toSet().length, 6);
      expect(
        manual.documents.every((d) => d.source.startsWith('domovoy://manual/')),
        true,
      );
      expect(
        manual.documents.every(
          (d) => d.sourceRevision == 'domovoy-support-2026-10-18-v1',
        ),
        true,
      );
      final pubspec = await File('pubspec.yaml').readAsString();
      expect(pubspec, contains('version: ${manual.packageVersion}'));
      final manifest =
          jsonDecode(await File('assets/support/manifest.json').readAsString())
              as Map;
      for (final doc in manifest['documents'] as List) {
        for (final source in (doc as Map)['provenance'] as List) {
          expect(
            await FileSystemEntity.type(source as String),
            isNot(FileSystemEntityType.notFound),
            reason: source,
          );
        }
      }
      await expectLater(
        BundledSupportManual.load(
          read: (p) async => p.endsWith('manifest.json')
              ? File(p).readAsString()
              : 'changed bytes',
        ),
        throwsFormatException,
      );
    },
  );
}
