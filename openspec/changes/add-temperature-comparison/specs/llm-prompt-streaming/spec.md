## ADDED Requirements

### Requirement: Optional sampling temperature
The provider-independent prompt input SHALL accept an optional finite sampling temperature from `0.0` through `2.0`, and the DeepSeek Chat Completions adapter SHALL serialize that value only when the caller supplies it.

#### Scenario: Temperature is supplied
- **WHEN** a prompt input carries a valid temperature
- **THEN** the DeepSeek request body contains the same numeric `temperature`

#### Scenario: Temperature is omitted
- **WHEN** an existing prompt input does not carry a temperature
- **THEN** the DeepSeek request body omits `temperature` and preserves the provider's default behavior

#### Scenario: Temperature is invalid
- **WHEN** a caller attempts to construct an input with a non-finite value or a value outside `0.0…2.0`
- **THEN** the input is rejected before any provider request can begin
