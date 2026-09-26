import '../llm/tools.dart';
import 'ids.dart';

/// The four tools enabled by default in Pi's coding agent.
///
/// These are protocol contracts. Platform-specific or remote executors are
/// registered separately, so the same tool calls work on every client.
abstract final class PiDefaultTools {
  static final List<ToolId> ids = List<ToolId>.unmodifiable(
    descriptors.map((descriptor) => ToolId(descriptor.name)),
  );

  static final List<LlmToolDescriptor>
  descriptors = List<LlmToolDescriptor>.unmodifiable(<LlmToolDescriptor>[
    LlmToolDescriptor(
      name: 'read',
      description:
          'Read a file. Use offset and limit to read part of a large text file.',
      parameters: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'path': <String, Object?>{
            'type': 'string',
            'description': 'Path to the file to read.',
          },
          'offset': <String, Object?>{
            'type': 'number',
            'description': 'First line to read, starting at 1.',
          },
          'limit': <String, Object?>{
            'type': 'number',
            'description': 'Maximum number of lines to read.',
          },
        },
        'required': <String>['path'],
      },
    ),
    LlmToolDescriptor(
      name: 'write',
      description:
          'Create or overwrite a file, creating parent directories as needed.',
      parameters: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'path': <String, Object?>{
            'type': 'string',
            'description': 'Path to the file to write.',
          },
          'content': <String, Object?>{
            'type': 'string',
            'description': 'Complete UTF-8 content of the file.',
          },
        },
        'required': <String>['path', 'content'],
      },
    ),
    LlmToolDescriptor(
      name: 'edit',
      description:
          'Apply exact, non-overlapping text replacements to an existing file. '
          'Each oldText must occur exactly once in the original file.',
      parameters: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'path': <String, Object?>{
            'type': 'string',
            'description': 'Path to the file to edit.',
          },
          'edits': <String, Object?>{
            'type': 'array',
            'description':
                'Targeted replacements, all matched against the original file.',
            'items': <String, Object?>{
              'type': 'object',
              'properties': <String, Object?>{
                'oldText': <String, Object?>{
                  'type': 'string',
                  'description': 'Unique text to replace.',
                },
                'newText': <String, Object?>{
                  'type': 'string',
                  'description': 'Replacement text.',
                },
              },
              'required': <String>['oldText', 'newText'],
            },
          },
        },
        'required': <String>['path', 'edits'],
      },
    ),
    LlmToolDescriptor(
      name: 'bash',
      description: 'Run a shell command in the workspace.',
      parameters: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'command': <String, Object?>{
            'type': 'string',
            'description': 'Shell command to execute.',
          },
          'timeout': <String, Object?>{
            'type': 'number',
            'description': 'Optional timeout in seconds.',
          },
        },
        'required': <String>['command'],
      },
    ),
  ]);
}
