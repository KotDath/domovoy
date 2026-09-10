## Purpose

Defines the first broker-mediated communication seam for addressed agent sessions, providing deterministic in-memory queued delivery without claiming durable or direct peer-to-peer execution.

## ADDED Requirements

### Requirement: Addressed broker delivery
The runtime SHALL route agent messages through a session router using the same stable `AgentSessionId` values used by session lifecycle and restoration, plus message and optional correlation identifiers, rather than direct references between agents. Sending SHALL return a typed receipt whose MVP outcomes are `queued` or `rejected`; the public outcome model SHALL reserve `steered` for a future implementation but MVP SHALL NOT report a message as steered.

#### Scenario: Message targets a registered open session
- **WHEN** a source sends a valid envelope to a registered open target session
- **THEN** the router records an immutable copy and returns a queued receipt with the same message and correlation identifiers

#### Scenario: Target cannot accept delivery
- **WHEN** the target session is unknown, closed, or its bounded inbox is full
- **THEN** the router returns a typed rejected receipt and does not report delivery or steering

#### Scenario: Steering is preferred by a caller
- **WHEN** a caller requests steering preference during MVP
- **THEN** the router queues the message without interrupting current work and reports `queued`, not `steered`

### Requirement: FIFO safe-boundary consumption
Each in-memory session inbox SHALL preserve accepted envelopes in FIFO order and deliver each queued envelope at most once to that session. An idle session SHALL consume queued messages before its next model request; a busy session SHALL not mutate an in-flight provider request or tool invocation and SHALL consume newly queued messages only at the next safe boundary before a subsequent model turn or run.

#### Scenario: Multiple messages are queued
- **WHEN** a target receives several accepted envelopes before a safe boundary
- **THEN** the target appends their payloads to context once in acceptance order with source and correlation metadata available to runtime events

#### Scenario: Message arrives during provider streaming
- **WHEN** an envelope is accepted while the target's provider stream is active
- **THEN** current streaming continues unchanged and the envelope is consumed before the target starts its next model turn

#### Scenario: Run ends before another model turn
- **WHEN** a message is queued during a final model turn
- **THEN** the message remains queued for the target's next run and is not silently marked consumed

### Requirement: Ephemeral messaging guarantee
MVP routing SHALL be local to one Dart process and SHALL NOT claim mailbox persistence, cross-device transport, automatic child-session creation, reply collection, or delivery across process death. Session-record persistence SHALL NOT implicitly persist its mailbox. Queue capacity SHALL be finite and configurable so agent messaging cannot grow memory without a bound.

#### Scenario: Process terminates with queued messages
- **WHEN** the application process ends before queued messages are consumed
- **THEN** those messages may be lost and no durable-delivery guarantee is presented

#### Scenario: Session record is restored
- **WHEN** a caller restores a session record whose previous in-process mailbox contained unconsumed envelopes
- **THEN** the restored session has an empty mailbox unless a future separately specified durable messaging implementation supplies those envelopes

#### Scenario: Queue capacity is reached
- **WHEN** the target inbox already contains its configured maximum number of envelopes
- **THEN** further sends are rejected deterministically until capacity is released

### Requirement: Correlated future completion seam
An envelope SHALL support an optional correlation identifier and reply-to message identifier so a later agent or future child-task runtime can return completion content through the same router. MVP SHALL route such envelopes as ordinary queued messages and SHALL NOT create a waiter, collector, background process, or automatic new turn solely from correlation metadata.

#### Scenario: Correlated reply is sent
- **WHEN** an agent sends a reply carrying the original correlation and reply-to identifiers
- **THEN** the target can observe those identifiers when consuming the queued payload, with no synchronous completion guarantee
