## ADDED Requirements

### Requirement: UI-safe deterministic catalog enumeration
The provider registry SHALL expose immutable credential-free provider groups suitable for selection surfaces. Each group SHALL carry stable provider identity, a non-blank display name supplied by profile/catalog metadata, and its registered models with existing model display names and capabilities. Groups and models SHALL preserve explicit registry/catalog order rather than depend on map hash order, feature-local identifiers, or a hard-coded count. Enumeration SHALL expose no provider clients, endpoints not already public metadata, credential references, effective secrets, or compatibility payloads.

#### Scenario: Built-in catalog is enumerated for UI
- **WHEN** a caller requests selectable groups from the built-in registry
- **THEN** it receives the three provider display groups and their eight models in declared registry/catalog order with model capabilities and no credential data

#### Scenario: Custom provider is registered
- **WHEN** a conforming custom profile with a display name and models is registered
- **THEN** enumeration includes that provider and its models using supplied metadata without a feature code change or provider-identifier branch

#### Scenario: Enumerated collections escape the registry
- **WHEN** a caller attempts to mutate an obtained provider group or model list
- **THEN** the registry contents and later enumerations remain unchanged
