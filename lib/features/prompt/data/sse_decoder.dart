import 'dart:convert';

final class SseDecoder {
  const SseDecoder();

  Stream<String> decode(Stream<List<int>> bytes) async* {
    var textBuffer = '';
    final dataLines = <String>[];

    await for (final textChunk in utf8.decoder.bind(bytes)) {
      textBuffer += textChunk;

      while (true) {
        final lineBreak = textBuffer.indexOf('\n');
        if (lineBreak < 0) {
          break;
        }

        var line = textBuffer.substring(0, lineBreak);
        textBuffer = textBuffer.substring(lineBreak + 1);
        if (line.endsWith('\r')) {
          line = line.substring(0, line.length - 1);
        }

        final event = _consumeLine(line, dataLines);
        if (event != null) {
          yield event;
        }
      }
    }

    if (textBuffer.isNotEmpty) {
      if (textBuffer.endsWith('\r')) {
        textBuffer = textBuffer.substring(0, textBuffer.length - 1);
      }
      final event = _consumeLine(textBuffer, dataLines);
      if (event != null) {
        yield event;
      }
    }

    if (dataLines.isNotEmpty) {
      yield dataLines.join('\n');
    }
  }

  static String? _consumeLine(String line, List<String> dataLines) {
    if (line.isEmpty) {
      if (dataLines.isEmpty) {
        return null;
      }
      final event = dataLines.join('\n');
      dataLines.clear();
      return event;
    }

    if (line.startsWith(':')) {
      return null;
    }

    if (line == 'data') {
      dataLines.add('');
      return null;
    }

    if (line.startsWith('data:')) {
      var value = line.substring(5);
      if (value.startsWith(' ')) {
        value = value.substring(1);
      }
      dataLines.add(value);
    }

    return null;
  }
}
