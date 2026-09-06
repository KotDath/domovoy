## ADDED Requirements

### Requirement: Day laboratory navigation
The application SHALL preserve the Day 1 one-shot workspace and Day 2 response laboratory while providing a distinct, clearly labeled Day 3 reasoning-strategy destination.

#### Scenario: User opens Day 3
- **WHEN** the user activates the Day 3 navigation destination from any application screen
- **THEN** the reasoning-strategy laboratory opens without replacing or clearing the independent Day 1 and Day 2 screen state

#### Scenario: User returns to an earlier day
- **WHEN** the user navigates from Day 3 back to Day 1 or Day 2
- **THEN** the selected earlier destination remains usable and Day 3 results are not added to its conversation or experiment state
