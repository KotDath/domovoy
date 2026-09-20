import 'package:path_provider/path_provider.dart';

import '../../agents/jsonl/jsonl_stream_storage.dart';
import '../../agents/jsonl/jsonl_stream_storage_io.dart';

/// Native memory streams use an independent application-support namespace.
const memoryJsonlStorageDirectoryName = 'memory-jsonl-v1';

JsonlStreamStorage createPlatformMemoryJsonlStreamStorage() {
  return JsonlFilesystemStreamStorage(
    applicationSupportDirectoryResolver: getApplicationSupportDirectory,
    namespaceDirectoryName: memoryJsonlStorageDirectoryName,
  );
}
