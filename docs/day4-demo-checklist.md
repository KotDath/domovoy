# Day 4 Linux Demo Checklist

Credential-safe demonstration of the temperature-comparison laboratory
(`0.0`, `0.7`, `1.2`) for the video-plus-code submission.

## 1. Prepare (no secrets on screen)

- [ ] Supply the API key only at runtime via app settings or
  `DEEPSEEK_API_KEY`; never paste it into a recorded terminal.
- [ ] Capture only the application window; hide unrelated desktop content
  and any settings field that could reveal a key.
- [ ] Open **Лаборатория · День 4** and confirm compact navigation labels
  `Запрос`, `День 2`, `День 3`, `День 4`.

## 2. Same-prompt proof

- [ ] Keep the built-in hybrid factual/creative prompt unchanged for the
  recorded run, or show the exact snapshot before pressing run.
- [ ] Show the three temperature controls at `0.0`, `0.7`, and `1.2`.
- [ ] Show the three-call disclosure before execution.
- [ ] Narrate that thinking is fixed off and `top_p` is omitted so
  temperature is the only sampling variable.

## 3. Run all three values

- [ ] Press **Запустить сравнение** and keep all three result cards
  visible with independent streamed answers.
- [ ] Confirm each card shows its applied temperature, answer or
  sanitized error, finish reason, token usage, and character count.
- [ ] If a lane fails, keep its partial output and continue the remaining
  schedule.

## 4. Evaluate and compare

- [ ] Assign accuracy, creativity, and diversity scores (`Без оценки` or
  `1…5`) on every terminal card.
- [ ] Add a practical-use note where the output would fit.
- [ ] Show lexical-diversity ratios and pairwise Jaccard similarity as
  descriptive evidence, not as semantic quality.
- [ ] Read the summary that repeats human scores and does not invent a
  winner.

## 5. Conclusions

- [ ] Distinguish official DeepSeek examples (coding/math `0.0`, data
  analysis `1.0`, conversation/translation `1.3`, creative writing
  `1.5`) from exercise inferences for `0.7` and `1.2`.
- [ ] State that one sample per temperature cannot estimate the full
  output distribution.
- [ ] Record which observed outputs best fit focused work versus
  creative variation.

## 6. Credential-safe capture

- [ ] No API key, settings input value, or secret terminal output appears
  in any frame or log.
- [ ] The same prompt, three values, three results, evaluations, lexical
  evidence, and conclusions stay legible.
- [ ] Review the video before delivery; re-record if any secret leaks.

## 7. Build / smoke (maintainer)

```sh
dart format .
flutter analyze
flutter test
flutter build linux --release
```

The opt-in Day 4 live smoke exercises temperatures `0.0`, `0.7`, and
`1.2` with thinking disabled. Supply `DEEPSEEK_API_KEY` only at runtime
and log aggregate non-secret evidence. Manual video recording stays
outside the repository.
