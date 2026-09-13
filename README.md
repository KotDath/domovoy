# Domovoy

Персональный ИИ-ассистент на Flutter с потоковыми ответами, сохраняемой историей
и подключением LLM через API. Эта ветка содержит результат отдельного учебного задания.

## Итог задания 8 — токены и переполнение контекста

Отдельное демо сравнивает короткий диалог, длинный диалог и превышение лимита.
Счётчики показывают только usage API: input, output, overall, cache read,
cache hit %, а при наличии разбивки — reasoning и видимый вывод.
Input уже включает cache read, output включает reasoning; overall = input + output.
«Вся история» означает накопленный расход физических API-вызовов с повторной
отправкой истории, а не оценку размера сохранённого текста. Денежная цена не
рассчитывается: сравнивается расход токенов.

### Результат эксперимента

Реальный DeepSeek, ручной браузерный прогон 13 сентября 2026 года:

| Сценарий / вызов | Input | Output | Overall | Накопленный overall |
| --- | ---: | ---: | ---: | ---: |
| Короткий диалог | 25 | 4 | 29 | 29 |
| Длинный, шаг 1 | 34 | 17 | 51 | 51 |
| Длинный, шаг 2 | 666 | 24 | 690 | 741 |
| Длинный, шаг 3 | 707 | 14 | 721 | 1462 |

Сценарии независимы. Длинный диалог суммарно израсходовал 1407 input и 55 output.
Последний вызов прочитал из кэша 512 токенов: cache hit 72,4%.
По мере накопления истории входной запрос вырос с 34 до 707 токенов.

Переполнение отправило один POST и получило HTTP 400:

```text
This model's maximum context length is 1048576 tokens. However, you requested 1100016 tokens (1100015 in the messages, 1 in the completion). Please reduce the length of the messages or completion.
```

Ответ модели не получен; API не сообщил usage, поэтому счётчики показывают «—».
В диагностическом режиме автоматическое сжатие и повторная отправка отключены:
видна исходная ошибка провайдера. Общий набор: 464 теста прошли.

### Запуск и видео

```sh
flutter run -d linux -t lib/day08_main.dart
```

Настройте ключ DeepSeek и последовательно запустите короткий, длинный сценарии
и кнопку переполнения. Покажите рост input, суммарный расход и ошибку.
[Подробный сценарий](docs/demos.md) · [Протокол проверок](docs/verification.md).
Видео не записано; подготовлены код и воспроизводимый сценарий.

## Linux development

The application stores an optional DeepSeek API-key override with Secret
Service. Install the `libsecret` runtime and development packages before
building the Linux desktop app. On Debian and Ubuntu:

```sh
sudo apt install libsecret-1-0 libsecret-1-dev
```

At runtime, Domovoy first uses the API key saved in its settings and otherwise
falls back to the `DEEPSEEK_API_KEY` process environment variable.
