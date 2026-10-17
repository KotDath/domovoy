final class HeadlessOptions {
  HeadlessOptions._(this.command, this.values, this.readOnly, this.help);
  final String command;
  final Map<String, String> values;
  final bool readOnly, help;
  bool get review => command == 'review';
  String get project => values['project']!;
  String get format => values['output-format'] ?? 'text';
  String get provider => values['provider'] ?? 'deepseek';
  String get model => values['model'] ?? 'deepseek-flash';
  int integer(String key, int fallback) =>
      int.parse(values[key] ?? '$fallback');

  static HeadlessOptions parse(List<String> args) {
    const keys = {
      'project',
      'prompt',
      'prompt-file',
      'provider',
      'model',
      'output-format',
      'output-last-message',
      'state-dir',
      'rag-url',
      'rag-query',
      'review-context',
      'system-prompt-file',
      'catalog-file',
      'reasoning',
      'timeout-seconds',
      'max-model-turns',
      'max-tool-calls',
      'max-input-bytes',
    };
    final values = <String, String>{};
    var readOnly = false;
    if (args.isEmpty || args.contains('--help') || args.contains('-h')) {
      return HeadlessOptions._('exec', values, true, true);
    }
    final command = args.first;
    if (command != 'exec' && command != 'review') {
      throw const FormatException('Expected exec or review.');
    }
    for (var i = 1; i < args.length; i++) {
      final arg = args[i];
      if (arg == '--read-only') {
        readOnly = true;
        continue;
      }
      if (!arg.startsWith('--') ||
          !keys.contains(arg.substring(2)) ||
          i + 1 >= args.length) {
        throw const FormatException(
          'Unknown option or missing value. See --help.',
        );
      }
      final key = arg.substring(2);
      if (values.containsKey(key)) {
        throw FormatException('Duplicate option: $key');
      }
      values[key] = args[++i];
    }
    if ((values['project'] ?? '').isEmpty) {
      throw const FormatException('--project is required.');
    }
    if (values.containsKey('prompt') && values.containsKey('prompt-file')) {
      throw const FormatException('Use one prompt source.');
    }
    if (!{'text', 'jsonl'}.contains(values['output-format'] ?? 'text')) {
      throw const FormatException('Expected text or jsonl output.');
    }
    if (!{'enabled', 'disabled'}.contains(values['reasoning'] ?? 'enabled')) {
      throw const FormatException('--reasoning expects enabled or disabled.');
    }
    for (final key in [
      'timeout-seconds',
      'max-model-turns',
      'max-tool-calls',
      'max-input-bytes',
    ]) {
      if (values.containsKey(key) && (int.tryParse(values[key]!) ?? 0) <= 0) {
        throw FormatException('$key must be positive.');
      }
    }
    if (command == 'review' &&
        (!values.containsKey('review-context') ||
            !values.containsKey('rag-url') ||
            !values.containsKey('system-prompt-file'))) {
      throw const FormatException(
        'review requires --review-context, --rag-url and trusted --system-prompt-file.',
      );
    }
    if (command == 'exec' && values.containsKey('review-context')) {
      throw const FormatException('Use review for PR context.');
    }
    return HeadlessOptions._(
      command,
      Map.unmodifiable(values),
      readOnly || command == 'review',
      false,
    );
  }
}

const headlessUsage = '''Domovoy headless (Dart VM; no Flutter engine)
  dart run bin/domovoy.dart exec --project ROOT [--prompt TEXT | --prompt-file FILE]
  dart run bin/domovoy.dart review --project SNAPSHOT --review-context FILE
    --system-prompt-file prompts/review-v2.md --rag-url http://127.0.0.1:8765
No prompt option: read UTF-8 stdin. Review defaults to the supplied PR context.
Options: --provider ID --model ID --catalog-file TRUSTED_JSON --reasoning enabled|disabled --read-only --rag-url URL --rag-query TEXT
  --output-format text|jsonl --output-last-message FILE --state-dir DIRECTORY
  --timeout-seconds N (1200) --max-model-turns N (10000)
  --max-tool-calls N (10000) --max-input-bytes N (400000)
Credentials: provider environment variable (DEEPSEEK_API_KEY for DeepSeek).
Exit: 0 success, 2 configuration/input, 1 execution failure, 130 cancellation.
Review never enables shell, writes or edits. General exec permits local tasks.
''';
