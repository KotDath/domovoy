# Day 5 Linux Demo Checklist

Credential-safe demonstration of the model-version comparison laboratory
(local Ollama `qwen3.5:2b`, DeepSeek V4 Flash, DeepSeek V4 Pro) for the
video-plus-code submission.

## 1. Prepare (no secrets on screen)

- [ ] Supply the DeepSeek API key only at runtime via app settings or
  `DEEPSEEK_API_KEY`; never paste it into a recorded terminal.
- [ ] Capture only the application window; hide unrelated desktop content
  and any settings field that could reveal a key.
- [ ] Open **Лаборатория · День 5** and confirm compact navigation labels
  `Запрос`, `День 2`, `День 3`, `День 4`, `День 5`.

## 2. Local Ollama prerequisite (optional live local lane)

The local service is an external dependency. The application does not
download, start, or assume Ollama.

```sh
ollama pull qwen3.5:2b
```

- Endpoint: `http://localhost:11434/v1/chat/completions`
- Model id: `qwen3.5:2b`
- Opt-in smoke:

```sh
flutter test integration_test/day5_ollama_smoke_test.dart
```

## 3. Same-prompt proof

- [ ] Keep the built-in Dart sparse-set ECS prompt unchanged for the
  recorded run, or show the exact snapshot before pressing run.
- [ ] Show the three identities, hosts, model ids, and source URLs:
  Ollama `qwen3.5:2b`, DeepSeek `deepseek-v4-flash`, DeepSeek
  `deepseek-v4-pro`.
- [ ] Show the three-call disclosure and the tier caveat (labels, not a
  quality judgment) before execution.

## 4. Run all three profiles

- [ ] Press **Запустить сравнение** and keep all three result cards
  visible with independent streamed answers.
- [ ] Confirm each card shows applied profile evidence, answer or
  sanitized error, finish reason, usage/cache tokens, TTFT, total
  duration, estimated cost or range, resource note, and structural
  checklist.
- [ ] If a lane fails, keep its partial output and continue the remaining
  schedule.

## 5. Evaluate and conclude

- [ ] Assign correctness, completeness, and practical-usefulness scores
  (`Без оценки` or `1…5`) on every terminal card and add notes.
- [ ] Record a short comparison conclusion suitable for the assignment.
- [ ] Show the objective per-run timing summary, all source links, and
  the single-run / resource / dated-pricing limitations.
- [ ] Do not invent a quality winner from one response.

## 6. Credential-safe capture

- [ ] No API key, settings input value, request header, or secret
  terminal output appears in any frame or log.
- [ ] Response bodies are not dumped; only the on-screen answers and
  aggregate measurements stay visible.
- [ ] The same prompt, three identities, results, timing, tokens, costs,
  quality evidence, conclusion, and links stay legible.
- [ ] Review the video before delivery; re-record if any secret leaks.

## 7. Build / smoke (maintainer)

```sh
dart format .
flutter analyze
flutter test
flutter test test/day5_fake_sse_test.dart
flutter build linux --release
```

Opt-in DeepSeek Flash/Pro smoke (runtime-only key, aggregate evidence):

```sh
flutter test integration_test/day5_live_smoke_test.dart
```

Manual video recording stays outside the repository.
