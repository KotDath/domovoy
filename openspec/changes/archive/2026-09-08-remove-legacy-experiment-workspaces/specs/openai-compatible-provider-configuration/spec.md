## REMOVED Requirements

### Requirement: Editable provider profiles
**Reason**: Existing profiles are Day 5 comparison-lane configuration rather than reusable agent profiles.

**Migration**: Saved `day5_*` profiles are not migrated; the future agent-profile capability will define a new model.

### Requirement: Safe endpoint and metadata validation
**Reason**: The validation contract is coupled to removed Day 5 profiles.

**Migration**: Future provider configuration will define its own validation requirements.

### Requirement: Optional bearer credential resolution
**Reason**: Profile-scoped credential resolution is coupled to removed Day 5 profiles.

**Migration**: Saved Day 5 credential overrides are no longer read; the retained one-shot DeepSeek credential setting remains unchanged.

### Requirement: Direct generic Chat Completions execution
**Reason**: Generic execution currently exists only to run Day 5 comparison profiles.

**Migration**: The retained one-shot DeepSeek transport remains available; generic provider execution will be reintroduced with the future agent layer.

### Requirement: Profile and credential persistence
**Reason**: Persisted comparison profiles and profile-scoped keys are being retired.

**Migration**: Existing `day5_*` records are not migrated or guaranteed to be wiped from platform storage, and the application stops reading them.

### Requirement: Auditable pricing and source metadata
**Reason**: Pricing metadata currently supports only the removed comparison experiment.

**Migration**: Future cost accounting will define versioned pricing independently.
