## ADDED Requirements

### Requirement: Day 4 laboratory navigation
The application SHALL preserve the independent Day 1 prompt workspace and Day 2–3 laboratories while providing a distinct, clearly labeled Day 4 temperature-comparison destination.

#### Scenario: User opens Day 4
- **WHEN** the user activates the Day 4 navigation destination from any application screen
- **THEN** the temperature laboratory opens without clearing the independent state of Days 1, 2, or 3

#### Scenario: User returns from Day 4
- **WHEN** the user navigates from Day 4 to an earlier destination
- **THEN** that destination remains usable and Day 4 results are not added to its prompt, experiment, or comparison state
