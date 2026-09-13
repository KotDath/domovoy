## MODIFIED Requirements

### Requirement: Application API-key override
The system SHALL allow a user to save a non-empty API key for each supported built-in API-key provider in application settings as a persistent provider-scoped override and SHALL allow the user to remove that provider's override explicitly. Changing one provider SHALL NOT replace another provider's key. The existing stored DeepSeek override SHALL remain effective and removable without re-entry.

#### Scenario: User saves an override
- **WHEN** the user enters a non-empty API key for a selected provider and saves the settings
- **THEN** the application persists the key in that provider's platform credential storage namespace and marks only that provider's application override as configured

#### Scenario: User removes an override
- **WHEN** the user activates the remove-key action for one provider
- **THEN** only that provider's persisted application override is deleted and subsequent resolution uses its next available credential source

#### Scenario: Blank key is not saved
- **WHEN** the user attempts to save an empty or whitespace-only value
- **THEN** the existing override remains unchanged and the settings UI requests a non-empty value

#### Scenario: Legacy DeepSeek key exists
- **WHEN** the prior DeepSeek secure-storage key exists and no newer DeepSeek override exists
- **THEN** DeepSeek remains configured without asking the user to enter the key again

### Requirement: Credential precedence
The system SHALL resolve an effective credential separately for the exact selected provider, using that provider's non-empty application override first and otherwise its declared non-empty process environment variable when available. No provider SHALL consume another provider's override or environment variable. Status views SHALL identify only configured source and availability, never a key value.

#### Scenario: Both credential sources exist
- **WHEN** both an application override and the selected provider's declared environment variable are non-empty
- **THEN** the application override is used for that provider's API request

#### Scenario: Only environment credential exists
- **WHEN** no application override exists and the selected provider's declared environment variable is non-empty
- **THEN** the environment credential is used for that provider's API request

#### Scenario: Override is removed while environment credential exists
- **WHEN** the user removes the application override and the provider's declared environment variable is non-empty
- **THEN** subsequent requests use that provider's environment credential without copying it into application settings

#### Scenario: Current platform has no process environment
- **WHEN** the current Flutter platform does not expose a process environment
- **THEN** the environment source is treated as absent and the application remains usable with an application override

#### Scenario: Other provider is configured
- **WHEN** only provider A has a usable key and provider B is selected
- **THEN** provider B remains unconfigured and cannot receive provider A's key

### Requirement: Missing-key failure
The system SHALL reject model invocation and authenticated model discovery before opening the selected provider's request when neither of its credential sources yields a non-empty key, and SHALL provide a user-facing error naming that provider and directing the user to its settings or declared environment variable.

#### Scenario: Prompt submitted without a key
- **WHEN** the user submits a valid prompt for an unconfigured provider
- **THEN** no network request is sent and a missing-key error explains that provider's supported credential sources

#### Scenario: Discovery starts without a key
- **WHEN** a provider requires authentication to list models but has no effective key
- **THEN** no listing request is sent and that provider displays a missing-credential discovery status

### Requirement: Credential confidentiality
The system SHALL avoid displaying, logging, persisting in session/catalog data, or embedding effective API keys or authorization headers in errors. It SHALL not prefill stored keys into editable fields and SHALL use the platform credential store for application overrides where available. Any provider error message shown to a user SHALL have effective credentials and authorization material redacted before presentation.

#### Scenario: Settings reopened after saving
- **WHEN** the user reopens settings after an override was saved
- **THEN** the UI indicates that the provider override exists without revealing its full value

#### Scenario: Request fails
- **WHEN** any configuration, transport, protocol, discovery, or provider error is presented or logged
- **THEN** the effective API key and authorization header are absent from the error content

#### Scenario: Browser user configures a key
- **WHEN** the application runs in a browser and presents API-key settings
- **THEN** the UI warns that a direct browser client cannot keep a provider key secret from the browser runtime
