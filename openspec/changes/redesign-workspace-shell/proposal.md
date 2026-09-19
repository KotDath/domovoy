## Why

The production Flutter workspace already has durable chats, provider discovery,
model/reasoning controls, and token accounting, but its presentation does not yet
match the user-approved `final-01` workspace design. Real Project → Chats data and
directory-access status are a prerequisite supplied by `add-project-workspaces`;
this change may start only after that dependency is accepted and then translates
those truthful facts into the approved shell without inventing richer filesystem,
pricing, or context-composition behavior.

## What Changes

- Restyle the existing chat workspace to the approved graphite/warm-neutral,
  periwinkle-accented `final-01` composition in dark, light, desktop, and narrow
  layouts while consuming the accepted durable Project/unassigned-chat runtime.
- Replace the current message-card hierarchy with compact right-aligned user
  blocks and prose-first assistant output, including bounded Markdown rendering
  and an honest per-live-run work-duration label.
- Move the truthful current token summary beside send as an upward context
  popover; unavailable values remain `—` and no estimated composition is added.
- Present the existing provider/model catalog as an upward provider → model
  cascade and reasoning as a separate upward picker, with narrow-screen sheets,
  keyboard/focus behavior, search, and bounded lazy lists for large catalogs.
- Keep existing provider credential/discovery settings reachable and visually
  coherent without displaying secrets or inventing connection results.
- Make System the startup theme and expose session-scoped System/Dark/Light
  selection; no persisted override is introduced in this slice.
- Retain all existing chat send/stop/select/create/delete, model/reasoning,
  provider, token-accounting, error, tool, and compaction behavior unless the
  approved presentation explicitly changes its placement or styling.
- Render real Project → Chats and `Без проекта` grouping, Project creation, and
  safe root/access status strictly through the accepted
  `add-project-workspaces` controller and capability results; never infer a
  Project, path, or permission from chat/provider data.
- Do not add or alter Project/session persistence, grant acquisition/enforcement,
  agent filesystem tools, attachment/file controls, context-composition
  categories, pricing/cost, usage charts, or other prototype-only sample data.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `chat-workspace-ui`: Refine the workspace composition, theme behavior,
  prose/Markdown presentation, live duration display, context-token control,
  real Project navigation, selectors, settings reachability, accessibility, and
  truthful exclusions to match approved `final-01` over the accepted Project
  runtime contract.

## Impact

- Affects Flutter application composition, chat/settings presentation,
  design-system tokens/dimensions, presentation projections for live duration,
  widget/golden tests, and four chat workspace golden images.
- Adds a bounded Flutter Markdown rendering dependency and its lockfile update;
  no platform-file or native application-identifier change is expected.
- Depends on accepted `add-project-workspaces`; implementation is blocked until
  that change is accepted. This change does not alter its Project/session schema,
  grant store/broker, provider protocols, credential storage, filesystem tools,
  or token-accounting sources.
