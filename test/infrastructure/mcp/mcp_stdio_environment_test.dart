import 'package:domovoy/infrastructure/mcp/stdio_environment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('passes only the allowlist plus explicit and secret values', () {
    final environment = buildStdioEnvironment(
      parent: const <String, String>{
        'PATH': '/usr/bin:/bin',
        'HOME': '/home/user',
        'LANG': 'C.UTF-8',
        'DEEPSEEK_API_KEY': 'sk-parent-secret',
        'OPENAI_API_KEY': 'sk-openai-secret',
        'DOMOVOY_MCP_TEST_SECRET': 'parent-app-secret',
      },
      explicit: const <String, String>{'NODE_ENV': 'production'},
      secretValues: const <String, String>{'API_TOKEN': 'token-123'},
      windows: false,
    );
    expect(environment['PATH'], '/usr/bin:/bin');
    expect(environment['HOME'], '/home/user');
    expect(environment['LANG'], 'C.UTF-8');
    expect(environment['NODE_ENV'], 'production');
    expect(environment['API_TOKEN'], 'token-123');
    expect(environment.containsKey('DEEPSEEK_API_KEY'), isFalse);
    expect(environment.containsKey('OPENAI_API_KEY'), isFalse);
    expect(environment.containsKey('DOMOVOY_MCP_TEST_SECRET'), isFalse);
  });

  test('explicit and secret values override allowlisted names', () {
    final environment = buildStdioEnvironment(
      parent: const <String, String>{'PATH': '/usr/bin'},
      explicit: const <String, String>{'PATH': '/opt/bin'},
      secretValues: const <String, String>{'HOME': '/srv/home'},
      windows: false,
    );
    expect(environment['PATH'], '/opt/bin');
    expect(environment['HOME'], '/srv/home');
  });

  test('windows keeps the operational allowlist and is case-insensitive', () {
    final environment = buildStdioEnvironment(
      parent: const <String, String>{
        'Path': r'C:\Windows\System32',
        'SystemRoot': r'C:\Windows',
        'TEMP': r'C:\Temp',
        'DEEPSEEK_API_KEY': 'sk-parent-secret',
      },
      explicit: const <String, String>{'PATH': r'C:\Tools'},
      secretValues: const <String, String>{'API_TOKEN': 'token-123'},
      windows: true,
    );
    expect(environment['PATH'], r'C:\Tools');
    expect(environment['SystemRoot'], r'C:\Windows');
    expect(environment['TEMP'], r'C:\Temp');
    expect(environment['API_TOKEN'], 'token-123');
    expect(environment.containsKey('DEEPSEEK_API_KEY'), isFalse);
    expect(
      environment.keys.where((key) => key.toLowerCase() == 'path').length,
      1,
    );
  });
}
