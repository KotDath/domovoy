import '../llm/json.dart';
import '../memory/validation.dart';
import 'errors.dart';

const defaultSoulMarkdown = '''# Domovoy

Ты персональный инженерный помощник. Помогай понять решение, выбрать следующий шаг и получить проверяемый результат.

## Манера
- Пиши прямо и спокойно.
- Не льсти и не соглашайся автоматически.
- Сначала сообщай результат или существенное препятствие.
- Учитывай язык, стиль и формат из USER.md.

## Достоверность
- Отделяй факты, слова пользователя, гипотезы и результаты инструментов.
- Не сообщай, что действие выполнено или проверка прошла, без подтверждения.
- При недостатке сведений называй, чего именно не хватает.
''';

const defaultUserMarkdown = '''# User profile

## STYLE
- Язык: русский
- Подробность: сбалансированная
- Тон: прямой и доброжелательный
- Уровень объяснения: адаптировать к вопросу

## FORMAT
- Структура ответа: сначала результат, затем необходимые детали
- Примеры кода: когда помогают понять решение
- Использование Markdown: да

## CONSTRAINTS
- Не выдумывать факты и выполненные действия

## CONTEXT
- Роль: не указана
- Технологии: не указаны
- Цели: не указаны
''';

const learnerUserMarkdown = '''# User profile

## STYLE
- Язык: русский
- Подробность: подробная
- Тон: спокойный и поддерживающий
- Уровень объяснения: начинающий разработчик

## FORMAT
- Структура ответа: пошагово, от простого к сложному
- Примеры кода: короткие и с пояснениями
- Использование Markdown: да

## CONSTRAINTS
- Расшифровывать новые термины
- Не пропускать важные промежуточные шаги

## CONTEXT
- Роль: начинающий разработчик
- Технологии: Dart и Flutter
- Цели: понимать причины решений, а не только получать готовый код
''';

const expertUserMarkdown = '''# User profile

## STYLE
- Язык: русский
- Подробность: техническая, без вводных основ
- Тон: прямой и профессиональный
- Уровень объяснения: опытный разработчик

## FORMAT
- Структура ответа: вывод, компромиссы, реализация
- Примеры кода: только когда проясняют контракт или крайний случай
- Использование Markdown: да

## CONSTRAINTS
- Указывать архитектурные последствия и риски
- Предпочитать небольшие проверяемые изменения

## CONTEXT
- Роль: senior software engineer
- Технологии: Dart, Flutter, API и локальная персистентность
- Цели: быстро оценивать решение и его эксплуатационные свойства
''';

enum ProfileTemplate { blank, learner, expert }

final class ProfileId {
  ProfileId(String value) : value = _normalizeId(value);

  final String value;

  Object toJson() => value;

  static ProfileId fromJson(Object? json) {
    if (json is! String) {
      throwPersonalization(
        PersonalizationErrorKind.persistence,
        'Некорректный идентификатор профиля.',
      );
    }
    return ProfileId(json);
  }

  @override
  bool operator ==(Object other) => other is ProfileId && other.value == value;

  @override
  int get hashCode => value.hashCode;
}

final class AssistantProfile {
  AssistantProfile({
    required this.id,
    required String name,
    required this.revision,
    required String soulMarkdown,
    required String userMarkdown,
    required this.createdAtMicros,
    required this.updatedAtMicros,
  }) : name = normalizeProfileName(name),
       soulMarkdown = normalizeSoulMarkdown(soulMarkdown),
       userMarkdown = normalizeUserMarkdown(userMarkdown) {
    if (revision < 0 ||
        createdAtMicros < 0 ||
        updatedAtMicros < createdAtMicros) {
      throwPersonalization(
        PersonalizationErrorKind.configuration,
        'Некорректная ревизия или время профиля.',
      );
    }
  }

  static const jsonType = 'personalization.profile';
  static const currentJsonVersion = 1;

  final ProfileId id;
  final String name;
  final int revision;
  final String soulMarkdown;
  final String userMarkdown;
  final int createdAtMicros;
  final int updatedAtMicros;

  factory AssistantProfile.create({
    required ProfileId id,
    required String name,
    required int nowMicros,
    ProfileTemplate template = ProfileTemplate.blank,
  }) {
    final user = switch (template) {
      ProfileTemplate.blank => defaultUserMarkdown,
      ProfileTemplate.learner => learnerUserMarkdown,
      ProfileTemplate.expert => expertUserMarkdown,
    };
    return AssistantProfile(
      id: id,
      name: name,
      revision: 0,
      soulMarkdown: defaultSoulMarkdown,
      userMarkdown: user,
      createdAtMicros: nowMicros,
      updatedAtMicros: nowMicros,
    );
  }

  AssistantProfile revise({
    String? name,
    String? soulMarkdown,
    String? userMarkdown,
    required int updatedAtMicros,
  }) => AssistantProfile(
    id: id,
    name: name ?? this.name,
    revision: revision + 1,
    soulMarkdown: soulMarkdown ?? this.soulMarkdown,
    userMarkdown: userMarkdown ?? this.userMarkdown,
    createdAtMicros: createdAtMicros,
    updatedAtMicros: updatedAtMicros,
  );

  AssistantProfile cloneAs({
    required ProfileId id,
    required String name,
    required int nowMicros,
  }) => AssistantProfile(
    id: id,
    name: name,
    revision: 0,
    soulMarkdown: soulMarkdown,
    userMarkdown: userMarkdown,
    createdAtMicros: nowMicros,
    updatedAtMicros: nowMicros,
  );

  Map<String, Object?> toJson() => typedJson(
    type: jsonType,
    version: currentJsonVersion,
    fields: <String, Object?>{
      'id': id.toJson(),
      'name': name,
      'revision': revision,
      'soulMarkdown': soulMarkdown,
      'userMarkdown': userMarkdown,
      'createdAtMicros': createdAtMicros,
      'updatedAtMicros': updatedAtMicros,
    },
  );

  static AssistantProfile fromJson(Object? json) {
    try {
      final map = decodeTypedJson(
        json,
        type: jsonType,
        version: currentJsonVersion,
      );
      return AssistantProfile(
        id: ProfileId.fromJson(map['id']),
        name: requireString(map, 'name'),
        revision: requireInt(map, 'revision'),
        soulMarkdown: requireString(map, 'soulMarkdown'),
        userMarkdown: requireString(map, 'userMarkdown'),
        createdAtMicros: requireInt(map, 'createdAtMicros'),
        updatedAtMicros: requireInt(map, 'updatedAtMicros'),
      );
    } on PersonalizationException {
      rethrow;
    } on Object {
      throwPersonalization(
        PersonalizationErrorKind.persistence,
        'Не удалось прочитать профиль.',
      );
    }
  }

  @override
  bool operator ==(Object other) =>
      other is AssistantProfile &&
      other.id == id &&
      other.name == name &&
      other.revision == revision &&
      other.soulMarkdown == soulMarkdown &&
      other.userMarkdown == userMarkdown &&
      other.createdAtMicros == createdAtMicros &&
      other.updatedAtMicros == updatedAtMicros;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    revision,
    soulMarkdown,
    userMarkdown,
    createdAtMicros,
    updatedAtMicros,
  );
}

String normalizeProfileName(String source) {
  final value = source.trim();
  if (value.isEmpty || value.runes.length > 80) {
    throwPersonalization(
      PersonalizationErrorKind.configuration,
      'Название профиля должно содержать от 1 до 80 символов.',
    );
  }
  _assertSafeText(value);
  return value;
}

String normalizeSoulMarkdown(String source) =>
    _normalizeDocument(source, label: 'SOUL.md', maxRunes: 4000);

String normalizeUserMarkdown(String source) {
  final value = _normalizeDocument(source, label: 'USER.md', maxRunes: 2500);
  for (final section in const <String>[
    '## STYLE',
    '## FORMAT',
    '## CONSTRAINTS',
    '## CONTEXT',
  ]) {
    if (!value.contains(section)) {
      throwPersonalization(
        PersonalizationErrorKind.configuration,
        'USER.md должен содержать раздел $section.',
      );
    }
  }
  return value;
}

String _normalizeDocument(
  String source, {
  required String label,
  required int maxRunes,
}) {
  final value = source.trim();
  if (value.isEmpty || value.runes.length > maxRunes) {
    throwPersonalization(
      PersonalizationErrorKind.configuration,
      '$label должен содержать от 1 до $maxRunes символов.',
    );
  }
  _assertSafeText(value);
  if (containsMemorySecret(value)) {
    throwPersonalization(
      PersonalizationErrorKind.secretDetected,
      '$label содержит данные, похожие на секрет.',
    );
  }
  return value;
}

void _assertSafeText(String value) {
  for (final rune in value.runes) {
    if (rune == 0 || rune == 0x7f || (rune < 0x20 && !_allowed(rune))) {
      throwPersonalization(
        PersonalizationErrorKind.configuration,
        'Текст содержит недопустимый управляющий символ.',
      );
    }
  }
}

bool _allowed(int rune) => rune == 0x09 || rune == 0x0a || rune == 0x0d;

String _normalizeId(String source) {
  final value = source.trim();
  if (!RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$').hasMatch(value)) {
    throwPersonalization(
      PersonalizationErrorKind.configuration,
      'Некорректный идентификатор профиля.',
    );
  }
  return value;
}
