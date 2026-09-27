import '../../../../core/mcp/mcp.dart';

/// Hard limits enforced by the local `digest` MCP server.
///
/// The limits bound every dimension of one `summarize_papers` invocation:
/// number of papers, prompt and abstract bytes, provider turns (always one),
/// output bytes and duration, and provider-reported token usage. They protect
/// the app from hostile input and from a runaway model answer, and they are
/// validated once so a misconfigured composition fails at construction, not
/// in the middle of a scheduled run.
final class DigestLimits {
  const DigestLimits({
    this.minPapers = 1,
    this.maxPapers = 10,
    this.maxTopicCharacters = 500,
    this.maxLanguageCharacters = 64,
    this.maxGoalCharacters = 1000,
    this.maxPaperTitleBytes = 4096,
    this.maxPaperAbstractBytes = 16384,
    this.maxTotalAbstractBytes = 65536,
    this.maxPromptBytes = 196608,
    this.maxOutputBytes = 65536,
    this.maxOverviewCharacters = 4000,
    this.maxFindingCharacters = 4000,
    this.maxLimitationCharacters = 1000,
    this.maxOutputTokens = 4096,
    this.maxTotalTokens = 65536,
    this.invocationTimeout = const Duration(seconds: 90),
  });

  /// Smallest accepted number of papers in one invocation.
  final int minPapers;

  /// Largest accepted number of papers in one invocation.
  final int maxPapers;

  final int maxTopicCharacters;
  final int maxLanguageCharacters;
  final int maxGoalCharacters;

  /// Per-paper byte cap for a title inside the prompt.
  final int maxPaperTitleBytes;

  /// Per-paper byte cap for an abstract inside the prompt.
  final int maxPaperAbstractBytes;

  /// Byte cap for all abstracts of one invocation together.
  final int maxTotalAbstractBytes;

  /// Byte cap for the complete prompt sent to the provider.
  final int maxPromptBytes;

  /// Byte cap for the raw model answer before parsing.
  final int maxOutputBytes;

  final int maxOverviewCharacters;
  final int maxFindingCharacters;
  final int maxLimitationCharacters;

  /// Requested provider output-token ceiling for the single model turn.
  final int maxOutputTokens;

  /// Token ceiling for provider-reported usage of the single model turn.
  final int maxTotalTokens;

  /// Deadline of the single provider turn.
  final Duration invocationTimeout;

  /// Validates cross-field invariants; returns `this` when acceptable.
  ///
  /// Called by [DigestSynthesizer] so an invalid configuration is rejected
  /// before any provider work starts.
  DigestLimits validate() {
    void positive(String name, int value) {
      if (value <= 0) {
        throwMcp(
          McpErrorKind.configuration,
          'Digest limit "$name" must be positive.',
        );
      }
    }

    positive('maxPapers', maxPapers);
    positive('minPapers', minPapers);
    if (minPapers > maxPapers) {
      throwMcp(
        McpErrorKind.configuration,
        'Digest limit "minPapers" must not exceed "maxPapers".',
      );
    }
    positive('maxTopicCharacters', maxTopicCharacters);
    positive('maxLanguageCharacters', maxLanguageCharacters);
    positive('maxGoalCharacters', maxGoalCharacters);
    positive('maxPaperTitleBytes', maxPaperTitleBytes);
    positive('maxPaperAbstractBytes', maxPaperAbstractBytes);
    positive('maxTotalAbstractBytes', maxTotalAbstractBytes);
    positive('maxPromptBytes', maxPromptBytes);
    positive('maxOutputBytes', maxOutputBytes);
    positive('maxOverviewCharacters', maxOverviewCharacters);
    positive('maxFindingCharacters', maxFindingCharacters);
    positive('maxLimitationCharacters', maxLimitationCharacters);
    positive('maxOutputTokens', maxOutputTokens);
    positive('maxTotalTokens', maxTotalTokens);
    if (invocationTimeout <= Duration.zero) {
      throwMcp(
        McpErrorKind.configuration,
        'Digest limit "invocationTimeout" must be positive.',
      );
    }
    if (maxTotalAbstractBytes < maxPaperAbstractBytes) {
      throwMcp(
        McpErrorKind.configuration,
        'Digest limit "maxTotalAbstractBytes" must not be smaller than '
        '"maxPaperAbstractBytes".',
      );
    }
    if (maxTotalTokens < maxOutputTokens) {
      throwMcp(
        McpErrorKind.configuration,
        'Digest limit "maxTotalTokens" must not be smaller than '
        '"maxOutputTokens".',
      );
    }
    return this;
  }
}
