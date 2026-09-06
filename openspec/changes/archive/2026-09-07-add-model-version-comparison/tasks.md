## 1. Configurable OpenAI-compatible providers

- [x] 1.1 Add immutable model-profile, tier, dialect, authentication, resource, source-link, and dated token-pricing models with the three documented Day 5 presets.
- [x] 1.2 Validate stable ids, non-empty labels/models, source URLs, finite non-negative prices, environment-variable names, and absolute endpoints; permit plain HTTP only for unauthenticated loopback hosts.
- [x] 1.3 Add versioned non-secret profile persistence and safe fallback from missing/corrupt storage, using the existing platform storage dependency without storing keys in profile JSON.
- [x] 1.4 Generalize credential resolution for unauthenticated, shared-DeepSeek, and profile-scoped bearer modes with saved-override-before-environment precedence and sanitized source status.
- [x] 1.5 Refactor direct Chat Completions construction into generic, Ollama-no-reasoning, and DeepSeek-no-thinking dialects plus a per-profile agent factory, preserving Days 1–4 request behavior and provider-neutral errors.
- [x] 1.6 Extend token-usage normalization source-compatibly with optional cache-hit/cache-miss prompt counters and preserve missing usage as unavailable.
- [x] 1.7 Add unit tests for presets, all validation boundaries, profile serialization/migration fallback, credential precedence/removal, no-auth headers, dialect-specific bodies, generic failures, cache usage, and all existing-agent regressions.

## 2. Day 5 measurements and orchestration

- [x] 2.1 Add the shared sparse-set ECS Dart prompt, immutable run/profile/lane snapshots, human evaluation fields, local conclusion state, and exact three-call accounting.
- [x] 2.2 Add an injectable monotonic elapsed-timer abstraction and freeze TTFT on the first non-empty answer delta and total duration on the first terminal condition.
- [x] 2.3 Implement exact and bounded per-million token cost calculations, explicit zero-provider-fee behavior, dated pricing snapshots, currency formatting, and unavailable states.
- [x] 2.4 Implement deterministic labeled checklist evidence for Dart code, sparse/dense mapping, swap-remove, O(1), component storage, and query concepts without producing a semantic score.
- [x] 2.5 Implement sequential weak/medium/strong execution using one trimmed prompt and exact profile snapshots, with thinking disabled, independent progressive answers, partial failures, and continuation to later lanes.
- [x] 2.6 Add generation/terminal guards, cancellation/disposal, synchronous-throw and silent-stream handling, duplicate-run locking, rating/note/conclusion updates, and full reset on the next valid run.
- [x] 2.7 Add deterministic tests for prompt/profile identity and order, timer behavior, token/cost paths, checklist evidence, failures, late/duplicate terminal events, cancellation, unavailable evidence, and evaluation reset.

## 3. Linux desktop interface

- [x] 3.1 Add a fifth persistent compact Day 5 navigation destination without clearing or mixing state from Days 1–5.
- [x] 3.2 Build the Day 5 shared-prompt screen with visible three-call disclosure, tier caveat, profile identities/hosts/models, source URLs, validation, run-all progress, and profile-settings access.
- [x] 3.3 Build a non-secret profile-settings dialog for editable endpoint/model/dialect/auth/environment/link/resource/pricing fields, masked blank key inputs, source-only credential status, save/remove/reset actions, and dismissal locking during persistence.
- [x] 3.4 Build three independent streamed result cards with applied profile evidence, answer/error, finish reason, usage/cache tokens, TTFT, total duration, estimated cost/range, resource note, and structural checklist.
- [x] 3.5 Add terminal-only correctness/completeness/practical-usefulness ratings, notes, an editable short conclusion, objective per-run timing summary, all source links, and explicit single-run/resource/pricing limitations without an invented quality winner.
- [x] 3.6 Implement readable three-column wide and stacked narrow layouts with long code/URLs wrapping or scrolling without clipping.
- [x] 3.7 Add widget tests for navigation retention, profile editing and secret safety, validation, execution locking, progressive/error states, measurement evidence, cost states, ratings/conclusion reset, links, limitations, and responsive layouts.

## 4. Integration, demonstration, and completion

- [x] 4.1 Add a loopback fake-SSE integration test proving a custom unauthenticated OpenAI-compatible profile sends the exact model/prompt without Authorization and normalizes streamed usage.
- [x] 4.2 Add an opt-in Linux Ollama smoke for installed `qwen3.5:2b` with aggregate non-secret output/timing/token evidence and documented service/model prerequisites.
- [x] 4.3 Add an opt-in DeepSeek smoke that runs exact Flash and Pro model ids with one runtime-only key and logs only aggregate model, status, timing, token, and estimated-cost evidence.
- [x] 4.4 Add a Day 5 video-plus-code checklist covering same-prompt proof, three identities/links, results, timing, tokens, costs, resource caveats, human quality evaluation, short conclusion, and credential-safe capture.
- [x] 4.5 Run `dart format .`, `flutter analyze`, `flutter test`, the Linux release build, fake-server integration, available local Ollama smoke, and DeepSeek Flash/Pro smoke without exposing credentials or response bodies.
- [x] 4.6 Verify implementation against OpenSpec, sync all three delta specs, archive the change, retain and push `feature/day-05`, and merge/push it into `main`; manual video recording remains outside automated implementation.
