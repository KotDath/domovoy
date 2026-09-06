# Day 3 Linux Demo Checklist

Credential-safe demonstration of the reasoning-strategy laboratory
(Direct, Step by step, Generated prompt, Expert group) for the
video-plus-code submission.

## 1. Prepare (no secrets on screen)

- [ ] Supply the API key only at runtime via app settings or
  `DEEPSEEK_API_KEY`; never paste it into a recorded terminal.
- [ ] Capture only the application window; hide unrelated desktop content
  and any settings field that could reveal a key.
- [ ] Open **Лаборатория · День 3** and confirm the banner states that
  native reasoning is fixed off for all four strategies.

## 2. Shared preset

- [ ] Keep the built-in four-house task unchanged for the recorded run.
- [ ] Show the unique reference grid: house 1 — Вера, кофе, попугай;
  house 2 — Анна, вода, собака; house 3 — Глеб, чай, рыбка;
  house 4 — Борис, сок, кошка.
- [ ] Narrate the left-to-right houses and one-to-one resident/drink/pet
  rules before launching the comparison.

## 3. Run all four strategies

- [ ] Press **Запустить 4 способа** and show the five-call disclosure
  (`N из 5`).
- [ ] Keep Direct, Step by step, Generated prompt, and Expert group cards
  visible with independent streamed answers.
- [ ] Open the generated prompt separately from the generated-strategy
  solver answer.
- [ ] If a stage fails, keep its partial output and sanitized error and
  continue the remaining schedule.

## 4. Rate and conclude

- [ ] Mark each completed card Без оценки / Точно / Частично / Неверно
  against the unique reference grid.
- [ ] Select the most accurate strategy and read the summary that labels
  the choice as a user judgment, not an LLM score.
- [ ] Do not invent an automatic winner.

## 5. Credential-safe capture

- [ ] No API key, settings input value, or secret terminal output appears
  in any frame or log.
- [ ] The four prompts/results, generated prompt, unique reference,
  verdicts, and selected conclusion stay legible.
- [ ] Review the video before delivery; re-record if any secret leaks.

## 6. Build / smoke (maintainer)

```sh
dart format .
flutter analyze
flutter test
flutter build linux --release
```

The opt-in Day 3 live smoke exercises all five stages with
`DEEPSEEK_API_KEY` supplied only at runtime and logs aggregate
non-secret evidence. Manual video recording stays outside the
repository.
