import 'dart:convert';

final class SseMessage {
  const SseMessage({this.event, required this.data});

  final String? event;
  final String data;
}

final class SseDecoder {
  const SseDecoder();

  Stream<String> decode(Stream<List<int>> bytes) {
    return decodeMessages(bytes).map((message) => message.data);
  }

  Stream<SseMessage> decodeMessages(Stream<List<int>> bytes) async* {
    var textBuffer = '';
    final dataLines = <String>[];
    String? eventName;

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

        final event = _consumeLine(line, dataLines, eventName);
        eventName = event.$1;
        if (event.$2 != null) {
          yield event.$2!;
        }
      }
    }

    if (textBuffer.isNotEmpty) {
      if (textBuffer.endsWith('\r')) {
        textBuffer = textBuffer.substring(0, textBuffer.length - 1);
      }
      final event = _consumeLine(textBuffer, dataLines, eventName);
      eventName = event.$1;
      if (event.$2 != null) {
        yield event.$2!;
      }
    }

    if (dataLines.isNotEmpty) {
      yield SseMessage(event: eventName, data: dataLines.join('\n'));
    }
  }

  static (String?, SseMessage?) _consumeLine(
    String line,
    List<String> dataLines,
    String? eventName,
  ) {
    if (line.isEmpty) {
      if (dataLines.isEmpty) {
        return (null, null);
      }
      final event = SseMessage(event: eventName, data: dataLines.join('\n'));
      dataLines.clear();
      return (null, event);
    }

    if (line.startsWith(':')) {
      return (eventName, null);
    }

    if (line == 'event' || line.startsWith('event:')) {
      var value = line == 'event' ? '' : line.substring(6);
      if (value.startsWith(' ')) {
        value = value.substring(1);
      }
      return (value, null);
    }

    if (line == 'data') {
      dataLines.add('');
      return (eventName, null);
    }

    if (line.startsWith('data:')) {
      var value = line.substring(5);
      if (value.startsWith(' ')) {
        value = value.substring(1);
      }
      dataLines.add(value);
    }

    return (eventName, null);
  }
}
