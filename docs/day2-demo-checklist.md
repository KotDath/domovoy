# Day 2 Linux Demo Checklist

Credential-safe demonstration of the response laboratory
(Format, Length, Stop) for the video-plus-code submission.

## 1. Prepare (no secrets on screen)

- [ ] Supply the API key only at runtime via app settings or
  `DEEPSEEK_API_KEY`; never paste it into a recorded terminal.
- [ ] Open **Настройки DeepSeek** and set **Режим Reasoning** to
  **выключено** for the recommended first pass.
- [ ] Close the settings dialog and confirm the laboratory banner shows
  `Reasoning: выключено`.
- [ ] Capture only the application window; hide unrelated desktop content.

## 2. Safe prompts and presets

- [ ] Format / JSON: base prompt `Придумай короткий рассказ о домовом.`,
  contract `title:string, summary:string, items:array:3`.
- [ ] Format / Markdown: headings `Обзор, Выводы`, маркированный список
  из `3` пунктов.
- [ ] Length: base prompt `Объясни, что такое домовой, коротко и понятно.`,
  `300` символов, `300` токенов.
- [ ] Stop: marker-producing prompt from the preset and exact marker
  `<END_OF_ANSWER>`.

## 3. Run all three experiments

- [ ] Format: press **Сравнить (2 API-вызова)**, show both
  `Без ограничений` / `С контролем` cards, validation evidence,
  applied control, finish reason, and usage.
- [ ] Length: run the pair, show actual Unicode character counts,
  configured limits, token usage, and any `length` truncation label.
- [ ] Stop: run the pair with the identical prompt, show marker /
  post-marker presence for both lanes and normalized finish reasons.
- [ ] Narrate each **Вывод** callout: instruction vs validation, character
  target vs token ceiling, exact stop-marker behavior.

## 4. First-pass-valid format behavior

- [ ] If the live provider satisfies the contract on the first attempt,
  present the real valid result and `Ремонт не требуется`.
- [ ] Do not fabricate a failure; deterministic tests cover the
  invalid-and-repair path (`Исправить формат` = 1 extra call, no retries).

## 5. Credential-safe capture

- [ ] No API key, settings input value, or secret terminal output appears
  in any frame or log.
- [ ] Reasoning state, shared prompts, controlled inputs, paired results,
  objective evidence, and conclusions are legible.
- [ ] Review the video before delivery; re-record if any secret leaks.

## 6. Build / smoke (maintainer)

```sh
dart format .
flutter analyze
flutter test
flutter build linux --release
```

Live smoke runs (Format, Length, Stop, optional repair) require the key
only at runtime and are not committed.
