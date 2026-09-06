## ADDED Requirements

### Requirement: Day 5 laboratory navigation
The application SHALL preserve the independent Day 1 prompt workspace and Day 2–4 laboratories while providing a distinct, clearly labeled Day 5 model-version comparison destination.

#### Scenario: User opens Day 5
- **WHEN** the user activates the Day 5 navigation destination from any application screen
- **THEN** the model comparison opens without clearing the independent state of Days 1, 2, 3, or 4

#### Scenario: User returns from Day 5
- **WHEN** the user navigates from Day 5 to an earlier destination
- **THEN** that destination remains usable and Day 5 results are not added to its prompt, experiment, or comparison state
