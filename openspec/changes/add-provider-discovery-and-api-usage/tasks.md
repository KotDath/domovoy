## 1. Catalog and Selection Foundation

- [x] 1.1 Record the 30 enabled API-key profiles with trusted endpoint, auth, transport, list capability, and feature limits in the manifest and provider research matrix. Registry composition tests cover the major families; cloud-account/OAuth and mixed-route OpenCode profiles are explicitly excluded.
- [x] 1.2 Ship a versioned bundled fallback and validated `models.dev/api.json` refresh without accepting remote endpoint overrides. Discovery tests cover server-only IDs, offline generations, pagination, and the V1 cached Perplexity ID that survives offline restart but retires after validated fresh metadata.
- [x] 1.3 Refresh documented provider lists, including authenticated DeepSeek, reconcile server-listed chat IDs with metadata or conservative unknown-bound text fallback, and filter known non-chat rows. Focused tests cover new/retired DeepSeek IDs and Fireworks, Anthropic, and Gemini pagination.
- [x] 1.4 Publish immutable catalog generations through the registry/controller with source, staleness, provider issues, and retry action. Registry/controller/widget tests and manual browser use cover publication, searchable selection, and refresh status; no provider-by-provider concurrency fixture matrix is claimed.
- [x] 1.5 Default new chats to listed `deepseek-flash`; retain obsolete IDs for restored JSONL history while requiring an explicit available model for future sends. Composition, selection, and restart tests plus live DeepSeek restore/switch evidence cover this path.

## 2. Provider Protocols and Credentials

- [x] 2.1 Use manifest-driven Chat Completions and Responses profiles without agent-runtime provider branches. Family-level request/SSE/usage/error tests and registry validation cover supported behavior; individual live authentication of all 30 profiles is not claimed.
- [x] 2.2 Add native Anthropic Messages text streaming with header auth and reported inclusive cache/thinking usage. Native fixture tests cover text and usage; tool continuation and explicit reasoning controls are marked unsupported.
- [x] 2.3 Add native Gemini generate-content text streaming with header auth and reported prompt/candidate/thought usage. Native fixture tests cover text and usage; tool continuation and explicit reasoning controls are marked unsupported.
- [x] 2.4 Expose provider-scoped key save/remove/source status through existing secure storage and environment precedence, retaining the legacy DeepSeek override and browser warning. Credential tests and manual two-provider key isolation, blank-key, missing-key, and restart checks provide evidence.
- [x] 2.5 Surface safe provider errors while redacting key/header material and classify DeepSeek's observed generic-code context-limit response as overflow. Adapter tests and real Day 8 HTTP 400/manual UI evidence cover the message and unknown failure usage.

## 3. Chat Presentation and Provider Usage

- [x] 3.1 Consume live catalog/provider status in picker and settings, search and lazily display large model lists, and show unavailable saved selections for explicit replacement. Widget tests and manual browser search/switch/reload verify the user path.
- [x] 3.2 Show API-reported inclusive input, output, and overall in compact/detail views with exclusive cache/reasoning breakdown and unknown values as dashes. Presenter tests and real DeepSeek/cache observations verify totals; no retained context estimate appears as API cost.
- [x] 3.3 Present safe provider errors as plain selectable text with prior partial output and no invented failure usage. Day 8 widget test and real overflow browser run verify the visible message and one failed ledger row.
- [x] 3.4 Provide a separate short/long/oversize Day 8 diagnostic launch with compaction/retry/preflight bypass limited to that run. Focused tests and real browser evidence verify a single overflow dispatch and unchanged normal-chat policy.

## 4. Integration and Evidence

- [x] 4.1 Authenticate against DeepSeek's model list and exercise normal/reasoning requests through the production stack; record reported inclusive/cache/reasoning figures without secrets in `docs/verification.md`.
- [x] 4.2 Reproduce a real Day 8 context overflow and compare successful short/long physical-call usage, exact history totals, raw API message, and absence of retry or fabricated failure tokens in browser evidence.
- [x] 4.3 Verify JSONL restart and model-switch behavior with production-stack tests, including restored Pro history switching to Claude, historical per-model usage, and V1 offline cached model recovery; manual browser checks cover restored history, selection, and provider key isolation. No session-envelope migration or secret-bearing artifact was introduced.
- [x] 4.4 Run format, analyze, full tests, Linux debug build, normal web build, strict OpenSpec validation, and repository diff check after V1; record commands, exits, limitations, and the exact frozen changed-tree fingerprint in feature state.
- [x] 4.5 Give each production runtime a fresh message/run ID namespace while preserving direct core factory defaults; verify a new production stack can append to a JSONL session with legacy `message-*` IDs after restart, then rerun final-tree checks.
