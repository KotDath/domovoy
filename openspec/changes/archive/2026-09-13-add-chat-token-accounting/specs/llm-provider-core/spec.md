## MODIFIED Requirements

### Requirement: Typed usage and completion metadata
The provider contract SHALL represent mutually exclusive input, cache-read, cache-write, non-reasoning output, and reasoning token counts as independently optional non-negative fields. It SHALL separately preserve provider-reported input, output, and overall parent totals; per-value provider-reported or derived-from-provider provenance; normalization completeness; and sanitized inconsistency markers. Provider usage updates SHALL describe cumulative snapshots for one physical invocation. Unavailable or invalid counters SHALL remain unknown rather than be estimated, coerced to zero, or fail an otherwise valid completion solely because optional usage metadata is malformed. The contract SHALL preserve an explicit unknown finish reason and distinguish normal stop, output limit, content filter, and tool-call completion when reported by a provider.

#### Scenario: Provider reports partial usage
- **WHEN** a provider reports only a subset of supported token counters
- **THEN** valid counters and parent totals are preserved with provenance, unavailable counters remain unknown, and completeness identifies that a full derivation is unavailable

#### Scenario: Provider reports inclusive totals
- **WHEN** declared provider semantics say input includes cached tokens or output includes reasoning tokens
- **THEN** the normalized exclusive component is derived by subtracting each known included child once, while the original parent total remains separately available

#### Scenario: Optional usage metadata is invalid
- **WHEN** a usage field is negative, non-integral, conflicts with an alias, or contradicts an inclusive parent
- **THEN** the affected metric/derivation is unavailable and marked inconsistent while unrelated valid usage and the terminal provider result remain observable

#### Scenario: Provider reports an unfamiliar finish reason
- **WHEN** the adapter receives a finish reason it does not recognize
- **THEN** completion is preserved with an unknown normalized finish reason rather than treated as a protocol failure

## ADDED Requirements

### Requirement: Dialect-owned provider usage normalization
Chat Completions and Responses adapters SHALL normalize usage at their provider boundary through testable semantic helpers configured by typed wire/dialect metadata, not provider-identifier conditionals in the agent runtime. A helper SHALL declare whether each parent total includes cache-read, cache-write, or reasoning children and SHALL apply checked non-negative subtraction only when the required operands are valid. Equal aliases SHALL be accepted once; conflicting aliases SHALL not be selected by silent precedence.

The built-in Chat Completions mapping SHALL support prompt/input, completion/output, and total aliases; direct or detail-based cached-token aliases; explicit cache-write aliases when supplied by a configured dialect; reasoning-token details; and cache-hit/cache-miss partitions without treating cache miss as cache write. The Responses mapping SHALL support input, output, and total counters, cached input details, reasoning output details, and configured explicit cache-write detail when present. Both SHALL use provider totals wherever valid and leave unsupported dimensions unavailable.

#### Scenario: Chat Completions reports DeepSeek-style cache partitions
- **WHEN** a compatible usage payload supplies prompt total, prompt cache-hit, prompt cache-miss, completion total, and overall total
- **THEN** the adapter emits cache read and uncached input as an internally validated partition, leaves cache write unavailable unless separately reported, and preserves valid parent/overall totals

#### Scenario: Chat Completions reports reasoning detail
- **WHEN** completion/output total and a supported reasoning-token detail are present
- **THEN** reasoning is provider-reported, non-reasoning output is derived by checked subtraction, and response-generated tokens equal the non-overlapping parent total

#### Scenario: Responses reports cached input and reasoning output
- **WHEN** a Responses usage object supplies input total with cached-token detail and output total with reasoning-token detail
- **THEN** cache read and reasoning remain provider-reported, exclusive input and output are derived without double count, cache write remains unavailable unless explicitly reported, and raw input/output totals remain available

#### Scenario: Alias values disagree
- **WHEN** two supported aliases for the same semantic counter are both present with different values
- **THEN** that semantic counter is inconsistent/unavailable, other independent counters remain usable, and neither adapter guesses which alias is authoritative

#### Scenario: Provider supplies repeated snapshots
- **WHEN** one adapter emits several usage updates and terminal usage for the same invocation
- **THEN** every event is marked as a cumulative snapshot for that invocation and no event is represented as an additive delta
