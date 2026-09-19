import 'package:domovoy/core/projects/projects.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('redacts paths, bookmarks, and long tokens', () {
    expect(
      redactUnsafeProjectText('/home/user/secret', fallback: 'safe'),
      'safe',
    );
    expect(
      redactUnsafeProjectText(r'C:\Users\me\proj', fallback: 'safe'),
      'safe',
    );
    expect(redactUnsafeProjectText('bookmark=AAAA', fallback: 'safe'), 'safe');
    expect(
      redactUnsafeProjectText('Каталог недоступен', fallback: 'safe'),
      'Каталог недоступен',
    );
  });

  test('json inspection rejects opaque keys', () {
    expect(
      jsonContainsUnsafeProjectMaterial(<String, Object?>{'bookmark': 'abc'}),
      isTrue,
    );
    expect(
      jsonContainsUnsafeProjectMaterial(<String, Object?>{'id': 'project-1'}),
      isFalse,
    );
  });
}
