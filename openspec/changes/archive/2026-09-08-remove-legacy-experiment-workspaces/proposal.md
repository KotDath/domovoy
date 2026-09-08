## Why

Domovoy is transitioning from a sequence of Day 2–5 model experiments to a product-oriented personal assistant. The experiment workspaces now dominate the application surface and codebase while providing no reusable conversation or agent runtime, so they should be removed before introducing the new agent layer.

## What Changes

- **BREAKING** Remove the Day 2 response-control, Day 3 reasoning-strategy, Day 4 temperature, and Day 5 model-version comparison destinations and their navigation.
- **BREAKING** Remove editable Day 5 comparison profiles, profile-scoped credential access, experiment pricing, evaluation helpers, presets, and persisted `day5_*` data integration without migration.
- Remove experiment-specific controllers, domain models, tests, live smoke tests, and demonstration checklists.
- Keep the existing one-shot prompt workspace as the sole temporary application surface, including its DeepSeek credential settings, progressive reasoning/answer streaming, usage parsing, and sanitized failures.
- Remove dependencies and dead configuration that become unused after the experiment workspaces are gone.
- Update project documentation and OpenSpec context so the retained prompt workspace, rather than the generated counter or day laboratories, is the current baseline.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `prompt-workspace`: Remove all Day 2–5 navigation requirements while retaining the independent one-shot prompt workspace.
- `response-control-comparison`: Remove the Day 2 response-control laboratory capability in full.
- `reasoning-strategy-comparison`: Remove the Day 3 reasoning-strategy laboratory capability in full.
- `temperature-comparison`: Remove the Day 4 temperature-comparison laboratory capability in full.
- `model-version-comparison`: Remove the Day 5 model-version comparison capability in full.
- `openai-compatible-provider-configuration`: Remove the Day 5 comparison-profile configuration and persistence capability in full.

## Impact

- Removes `lib/features/lab`, `lib/features/reasoning`, `lib/features/temperature`, and `lib/features/comparison`, together with their wiring in `lib/app.dart`.
- Removes corresponding unit/widget tests, `integration_test/day2_*` through `day5_*`, and `docs/day2-*` through `day5-*`.
- Retains `lib/features/prompt`, `lib/features/settings`, `lib/core/environment`, the current OpenAI-compatible streaming transport, and all configured Flutter platforms.
- Stops reading legacy Day 5 secure-storage keys and profile documents without migration or a guaranteed on-device wipe; users may need to configure credentials again when the future agent-profile capability is introduced.
- Does not introduce `AgentProfile`, `AgentSession`, `AgentRunner`, conversation persistence, tools, or provider management; those belong to a subsequent independently verifiable change.
