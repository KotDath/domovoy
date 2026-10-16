import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Set only ordinary file permissions: archive set-ID/sticky bits never apply.
/// Android uses libc directly and does not require a shell or chmod executable.
void applyPortableFileMode(String path, {required bool executable}) {
  if (Platform.isWindows) {
    if (executable) {
      throw const FormatException(
        'Executable checkout import requires POSIX file permissions',
      );
    }
    return;
  }
  final chmod = DynamicLibrary.process()
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Uint32),
        int Function(Pointer<Utf8>, int)
      >('chmod');
  final nativePath = path.toNativeUtf8(allocator: calloc);
  try {
    if (chmod(nativePath, executable ? 0x1ed : 0x1a4) != 0) {
      throw const FileSystemException('Cannot preserve checkout file mode');
    }
  } finally {
    calloc.free(nativePath);
  }
}
