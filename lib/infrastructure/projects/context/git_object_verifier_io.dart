import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Bounded verifier for portable loose Git objects. Pack files and alternates
/// are never interpreted. The host exporter uses standard Git to normalize them.
final class GitObjectVerifier {
  GitObjectVerifier({required this.objects, required this.safePath});
  final String objects;
  final Future<String> Function(String) safePath;
  static const maxObjectBytes = 32 * 1024 * 1024;
  static const maxTotalBytes = 128 * 1024 * 1024;
  static const maxObjects = 15000;

  Future<void> verify(String head, Set<String> shallow) async {
    final hashBytes = head.length ~/ 2;
    final pending = <_Requirement>[_Requirement(head, 'commit', 0)];
    final verified = <String, String>{};
    var total = 0;
    while (pending.isNotEmpty) {
      final next = pending.removeLast();
      final previous = verified[next.oid];
      if (previous != null) {
        if (previous != next.type) {
          throw const FormatException('Git object type mismatch');
        }
        continue;
      }
      if (verified.length >= maxObjects || next.depth > 256) {
        throw const FormatException('Git graph exceeds verification limits');
      }
      final path =
          '$objects/${next.oid.substring(0, 2)}/${next.oid.substring(2)}';
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const FormatException(
          'Missing loose Git object; packed or incomplete repositories require portable export',
        );
      }
      final file = File(await safePath(path));
      if (await file.length() > maxObjectBytes) {
        throw const FormatException('Compressed Git object exceeds limit');
      }
      final sink = _LimitedObjectSink();
      final decoder = ZLibDecoder().startChunkedConversion(sink);
      decoder.add(await file.readAsBytes());
      decoder.close();
      final data = sink.bytes.takeBytes();
      total += data.length;
      if (total > maxTotalBytes) {
        throw const FormatException('Git graph exceeds decoded byte limit');
      }
      final digest = (hashBytes == 20 ? sha1 : sha256).convert(data).toString();
      if (digest != next.oid) {
        throw const FormatException('Git object hash mismatch');
      }
      final delimiter = data.indexOf(0);
      if (delimiter <= 0 || delimiter > 96) {
        throw const FormatException('Invalid Git object header');
      }
      final header = ascii.decode(data.sublist(0, delimiter));
      final match = RegExp(
        r'^(commit|tree|blob) (0|[1-9][0-9]*)$',
      ).firstMatch(header);
      if (match == null ||
          match[1] != next.type ||
          int.parse(match[2]!) != data.length - delimiter - 1) {
        throw const FormatException('Git object type/size mismatch');
      }
      final body = Uint8List.sublistView(data, delimiter + 1);
      verified[next.oid] = next.type;
      void require(String oid, String type) {
        if (pending.length + verified.length >= maxObjects * 2) {
          throw const FormatException('Git graph exceeds reference limit');
        }
        pending.add(_Requirement(oid, type, next.depth + 1));
      }

      if (next.type == 'commit') {
        final boundary = _headerEnd(body);
        if (boundary < 0 || boundary > 65536) {
          throw const FormatException('Invalid Git commit header');
        }
        final lines = latin1.decode(body.sublist(0, boundary)).split('\n');
        final oidPattern = RegExp('^[0-9a-f]{${head.length}}\$');
        if (!lines.first.startsWith('tree ') ||
            !oidPattern.hasMatch(lines.first.substring(5)) ||
            lines.where((line) => line.startsWith('tree ')).length != 1 ||
            !lines.any((line) => line.startsWith('author ')) ||
            !lines.any((line) => line.startsWith('committer '))) {
          throw const FormatException('Invalid Git commit references');
        }
        require(lines.first.substring(5), 'tree');
        for (final line in lines.where((line) => line.startsWith('parent '))) {
          final oid = line.substring(7);
          if (!oidPattern.hasMatch(oid)) {
            throw const FormatException('Invalid Git parent');
          }
          if (!shallow.contains(next.oid)) require(oid, 'commit');
        }
      } else if (next.type == 'tree') {
        var offset = 0;
        final names = <String>{};
        while (offset < body.length) {
          final space = body.indexOf(32, offset),
              zero = body.indexOf(0, offset);
          if (space < offset ||
              zero <= space + 1 ||
              zero + 1 + hashBytes > body.length) {
            throw const FormatException('Invalid Git tree entry');
          }
          final mode = ascii.decode(body.sublist(offset, space));
          final name = body.sublist(space + 1, zero);
          if (name.contains(47) ||
              !names.add(base64Encode(name)) ||
              (name.length == 1 && name[0] == 46) ||
              (name.length == 2 && name.every((b) => b == 46))) {
            throw const FormatException('Invalid Git tree name');
          }
          final oid = body
              .sublist(zero + 1, zero + 1 + hashBytes)
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join();
          switch (mode) {
            case '40000':
              require(oid, 'tree');
            case '100644':
            case '100755':
            case '120000':
              require(oid, 'blob');
            case '160000':
              break; // Gitlinks refer to a different repository.
            default:
              throw const FormatException('Unsupported Git tree mode');
          }
          offset = zero + 1 + hashBytes;
        }
      }
    }
  }
}

int _headerEnd(List<int> bytes) {
  for (var i = 0; i + 1 < bytes.length && i <= 65536; i++) {
    if (bytes[i] == 10 && bytes[i + 1] == 10) return i;
  }
  return -1;
}

final class _Requirement {
  const _Requirement(this.oid, this.type, this.depth);
  final String oid, type;
  final int depth;
}

final class _LimitedObjectSink implements Sink<List<int>> {
  final bytes = BytesBuilder(copy: false);
  var length = 0;
  @override
  void add(List<int> data) {
    length += data.length;
    if (length > GitObjectVerifier.maxObjectBytes + 128) {
      throw const FormatException('Decoded Git object exceeds limit');
    }
    bytes.add(data);
  }

  @override
  void close() {}
}
