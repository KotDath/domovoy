## 1. Foundation

- [x] 1.1 Add the general streamed HTTP and platform secure-storage dependencies, including the native configuration required by the selected storage plugin.
- [x] 1.2 Create the feature-oriented module structure and keep `main.dart` as a thin application entry point.
- [x] 1.3 Define `AgentInput`, the abstract `Agent.prompt` stream contract, typed reasoning/answer/completion/failure events, and sanitized failure categories.

## 2. Credential Resolution

- [x] 2.1 Define injectable application-override, environment-reader, and credential-resolver interfaces without exposing secret values to presentation state.
- [x] 2.2 Implement the secure persistent DeepSeek override store with save, configured-status, and explicit-delete operations.
- [x] 2.3 Implement conditional environment readers that use `DEEPSEEK_API_KEY` on `dart:io` platforms and report no process environment on web.
- [x] 2.4 Implement and unit-test override-first resolution, environment fallback, trimming/blank handling, clearing fallback, and missing-key failure before networking.

## 3. OpenAI-Compatible Streaming Adapter

- [x] 3.1 Implement and unit-test an SSE decoder that handles UTF-8 and line fragmentation, LF/CRLF framing, comments, multiple data lines, `[DONE]`, and premature EOF.
- [x] 3.2 Add an injectable OpenAI-compatible Chat Completions provider profile and the DeepSeek profile for `https://api.deepseek.com/chat/completions`, `deepseek-v4-flash`, thinking enabled, and high reasoning effort.
- [x] 3.3 Implement the direct streamed HTTP request with bearer authentication and a single current user message, ensuring no history or sampling parameters are sent.
- [x] 3.4 Normalize `delta.reasoning_content` and `delta.content` into domain events and handle metadata-only chunks and the terminal marker.
- [x] 3.5 Convert non-success responses, provider errors, malformed events, network failures, and interrupted streams into sanitized terminal failures while preserving emitted deltas.
- [x] 3.6 Unit-test request headers/body, provider-field normalization, terminal behavior, failure mapping, stateless repeated calls, and absence of credential text in errors.

## 4. Prompt State and Workspace

- [x] 4.1 Implement an injectable prompt controller with immutable state, delta accumulation, one-active-request enforcement, result reset, partial-output retention, and safe stream disposal.
- [x] 4.2 Replace the counter screen with responsive prompt and output areas that use side-by-side layout when wide and stacked layout when narrow.
- [x] 4.3 Add prompt validation, submit/loading states, independent resubmission, and prevention of concurrent calls.
- [x] 4.4 Add a muted, accessible reasoning disclosure that starts expanded on first content, continues accumulating while collapsed, and does not control final-answer visibility.
- [x] 4.5 Add progressive final-answer rendering and sanitized error presentation, including a settings action for missing credentials.

## 5. API-Key Settings and Composition

- [x] 5.1 Build the settings UI for entering a replacement key, saving it, explicitly removing it, and reporting the active source without prefilling or revealing a stored secret.
- [x] 5.2 Add the browser-specific direct-key warning and verify that settings remain usable when no process environment is available.
- [x] 5.3 Wire storage, environment reader, resolver, streamed HTTP client, DeepSeek provider profile, agent, controller, and screens in the application composition root.

## 6. Verification

- [x] 6.1 Replace the generated counter test with controller and widget tests covering narrow/wide layout, progressive reasoning/answer output, disclosure behavior, loading, resubmission, missing key, partial failure, and settings flows.
- [x] 6.2 Run `dart format .`, `flutter analyze`, and `flutter test`, and resolve all failures.
- [x] 6.3 Run a Linux desktop build to validate the primary target, conditional imports, and `libsecret` secure-storage integration, documenting any external toolchain limitation.
