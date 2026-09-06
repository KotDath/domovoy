# LLM Credentials Specification

## Purpose

Defines how Domovoy accepts, stores, resolves, and protects the API key required for direct DeepSeek prompt execution.

## Requirements

### Requirement: Application API-key override
The system SHALL allow a user to save a non-empty DeepSeek API key in application settings as a persistent override and SHALL allow the user to remove that override explicitly.

#### Scenario: User saves an override
- **WHEN** the user enters a non-empty API key and saves the settings
- **THEN** the application persists the key in platform credential storage and marks an application override as configured

#### Scenario: User removes an override
- **WHEN** the user activates the remove-key action
- **THEN** the persisted application override is deleted and subsequent resolution uses the next available credential source

#### Scenario: Blank key is not saved
- **WHEN** the user attempts to save an empty or whitespace-only value
- **THEN** the existing override remains unchanged and the settings UI requests a non-empty value

### Requirement: Credential precedence
The system SHALL resolve the effective DeepSeek credential by using a non-empty application override first and otherwise using a non-empty `DEEPSEEK_API_KEY` value from the running process environment when that environment is available on the current platform.

#### Scenario: Both credential sources exist
- **WHEN** both an application override and `DEEPSEEK_API_KEY` are non-empty
- **THEN** the application override is used for the API request

#### Scenario: Only environment credential exists
- **WHEN** no application override exists and `DEEPSEEK_API_KEY` is non-empty
- **THEN** the environment credential is used for the API request

#### Scenario: Override is removed while environment credential exists
- **WHEN** the user removes the application override and `DEEPSEEK_API_KEY` is non-empty
- **THEN** subsequent requests use the environment credential without requiring it to be copied into application settings

#### Scenario: Current platform has no process environment
- **WHEN** the current Flutter platform does not expose a process environment
- **THEN** the environment source is treated as absent and the application remains usable with an application override

### Requirement: Missing-key failure
The system SHALL reject prompt execution before opening a provider request when neither credential source yields a non-empty key, and SHALL provide a user-facing error that directs the user to settings or the `DEEPSEEK_API_KEY` environment variable.

#### Scenario: Prompt submitted without a key
- **WHEN** the user submits a valid prompt with no application override and no environment key
- **THEN** no network request is sent and a missing-key error explains both supported credential sources

### Requirement: Credential confidentiality
The system SHALL avoid displaying, logging, or embedding the effective API key in errors, SHALL not prefill the stored key back into an editable field, and SHALL use the platform credential store for application overrides where available.

#### Scenario: Settings reopened after saving
- **WHEN** the user reopens settings after an override was saved
- **THEN** the UI indicates that an override exists without revealing its full value

#### Scenario: Request fails
- **WHEN** any configuration, transport, protocol, or provider error is presented or logged
- **THEN** the effective API key is absent from the error content

#### Scenario: Browser user configures a key
- **WHEN** the application runs in a browser and presents API-key settings
- **THEN** the UI warns that a direct browser client cannot keep a provider key secret from the browser runtime
