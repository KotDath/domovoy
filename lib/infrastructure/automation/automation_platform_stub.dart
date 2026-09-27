/// Platform predicate for the automation foreground policy.
///
/// The observer pauses timers when the application leaves the foreground only
/// on mobile platforms; desktop keeps working while the process lives. Web is
/// treated like desktop (the browser itself throttles timers, and the
/// scheduler always recomputes the next instant from the persisted
/// `nextDueAt`).
bool automationPausesInBackground() => false;
