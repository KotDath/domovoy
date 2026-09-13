## Purpose

This capability lets a viewer compare context-retention strategies on the same real model requests and inspect independently persisted branches and provider-reported spending.

## ADDED Requirements

### Requirement: Identical scenario comparison
The demo SHALL offer the same fourteen ordered prompts to sliding-window, explicit-facts, and branching strategies, with a persistent strategy selector, selected-strategy next-step control, common next-step control, and run-all control. It SHALL show their actual final answers alongside eight labeled expected facts, without manufacturing a quality score or answer.

#### Scenario: Run the common scenario
- **WHEN** the user runs the comparison
- **THEN** all three strategies receive each prompt in the same order and their final answers and progression remain visible after reload

#### Scenario: Select one strategy
- **WHEN** the user selects one strategy and advances it alone
- **THEN** only that strategy advances, the selection survives reload, and a later common comparison catches up the others from their own next prompts

### Requirement: Distinct retained context
The sliding strategy SHALL send only the last two completed user/assistant pairs. The explicit-facts strategy SHALL update supported key-value facts before generating a response, replace superseded values, and send those facts plus the same short tail. The branching strategy SHALL retain its own full conversation history and SHALL NOT summarize it.

#### Scenario: Replace the budget
- **WHEN** the scenario changes the budget from 120000 to 150000
- **THEN** the explicit-facts state contains only the current budget value before that turn reaches the model and retains it after reload

#### Scenario: Old sliding context falls out
- **WHEN** more than two complete pairs precede a new request
- **THEN** the sliding strategy does not send older pairs in that request

### Requirement: Independent branches
The demo SHALL create a checkpoint as soon as the branching strategy completes step eight and allow A and B to continue independently with distinct waiting-list and family-appointment prompts. It SHALL expose each branch's parent and checkpoint, restore them after reload, and count each branch's new API spend without counting inherited calls twice.

#### Scenario: Divergent continuations
- **WHEN** branches A and B each receive their own continuation after the checkpoint
- **THEN** neither branch's request contains the sibling continuation and each has a unique invocation identity and separate new-spend ledger

### Requirement: API-only accounting and safe browser run
The demo SHALL derive visible input, output, cache, and overall token counts solely from physical provider usage, show unknown when absent, and include failed or cancelled attempts in the physical ledger. The browser entry SHALL keep the real API key on the local relay host.

#### Scenario: Missing provider usage
- **WHEN** a physical request ends without provider usage
- **THEN** its token dimensions display unknown rather than zero or an estimate

#### Scenario: Browser relay
- **WHEN** the browser demo calls DeepSeek through the loopback relay
- **THEN** the bundled client contains only a nonsecret marker and the relay supplies the secret from its environment
