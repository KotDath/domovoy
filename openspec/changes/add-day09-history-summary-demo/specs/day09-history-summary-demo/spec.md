## Purpose

Demonstrates repeatable agent-session history summarization against an uncompacted control using the same brief, while preserving recent verbatim turns and reporting actual provider cost.

## ADDED Requirements

### Requirement: Cadenced summary of completed raw messages
The Day 9 summarized agent SHALL replace older complete user/assistant interactions with a generated summary after each 10 newly completed raw user/assistant messages. It SHALL retain the last two complete user/assistant pairs verbatim. A pending user message or duplicate evaluation SHALL NOT advance the cadence, and a no-change result SHALL NOT persist a new cadence checkpoint.

#### Scenario: First and repeated compaction
- **WHEN** the fifth and then tenth completed user/assistant pairs are acknowledged
- **THEN** one summary compaction occurs at each 10-message boundary, with four most recent raw messages retained after each accepted compaction

#### Scenario: Pending or no-change evaluation
- **WHEN** a request is pending, the trigger is evaluated again without a new completed pair, or the compactor returns no change
- **THEN** no cadence checkpoint advances and no extra summary generation is persisted

### Requirement: Separate durable summary and correct usage attribution
An accepted summary SHALL be stored as a generated prefix with compaction provenance rather than replacing the retained raw messages in the user-visible history. A fresh runtime SHALL restore the summary, retained messages, cadence checkpoint, and physical invocation ledger. Summary-provider calls SHALL be charged exactly once as compaction usage, separately from assistant response usage.

#### Scenario: Restart after a summary
- **WHEN** a summarized session is closed and restored from JSONL
- **THEN** its generated summary, two retained pairs, cadence counter, and prior summary/assistant ledger entries remain available for the next turn

#### Scenario: Summary has measurable cost
- **WHEN** one or more provider calls create a summary
- **THEN** each physical call appears once with its reported model and usage, and the display identifies summary overhead independently of ordinary answers

### Requirement: Comparable Day 9 demonstration
The Day 9 page SHALL execute the same ordered 14-prompt brief independently in an uncompacted and a summarized agent session. It SHALL offer both one-step and one-click complete execution, show each mode's latest and final answer, display the saved summary and retained raw turns, and compare provider-reported input/output/cache/overall totals and latest-request values without labeling estimates as API cost. Missing usage SHALL remain unknown, and quality or savings SHALL be described from observed answers and totals rather than prefilled claims.

#### Scenario: Complete comparison
- **WHEN** the user runs all 14 prompts
- **THEN** both modes receive the same prompts in order, answers can be read side by side, and the page shows actual totals including separate summary overhead

#### Scenario: Interrupted or partial comparison
- **WHEN** the user runs only the next step or a provider request fails
- **THEN** the completed steps and measured usage remain visible, and the page does not invent values or report an unexecuted comparison as complete

### Requirement: Safe browser demonstration
The browser entry SHALL reuse the local relay to send DeepSeek requests without embedding the real API key in compiled assets. The normal production app SHALL retain its existing compaction configuration.

#### Scenario: Browser launch
- **WHEN** the Day 9 browser page runs through the local relay
- **THEN** it uses the real production provider/runtime path and a public client marker, while the secret key remains server-side
