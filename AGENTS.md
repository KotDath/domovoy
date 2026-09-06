# Repository guidelines

## Project

Domovoy is a personal AI assistant built as a Flutter application. The Dart
package name is `domovoy`, and the native application identifier prefix is
`ru.kotdath`.

## OpenSpec workflow

- Use the OpenSpec skills in `.agents/skills/` for non-trivial features and
  behavior changes.
- Start new planned work with `$openspec-propose`, implement it with
  `$openspec-apply-change`, and check the result with
  `$openspec-verify-change` before archiving it.
- Keep proposals and tasks focused on one independently reviewable change.

## Flutter checks

- Format Dart sources with `dart format .`.
- Run `flutter analyze` and `flutter test` before considering an implementation
  complete.
- Keep platform-specific code aligned with the application identifier
  `ru.kotdath.domovoy`.
