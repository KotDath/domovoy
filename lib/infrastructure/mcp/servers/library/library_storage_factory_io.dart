import 'package:path_provider/path_provider.dart';

import '../../../agents/jsonl/jsonl_stream_storage.dart';
import '../../../agents/jsonl/jsonl_stream_storage_io.dart';
import 'library_storage_namespace.dart';

JsonlStreamStorage? createPlatformLibraryJsonlStreamStorage() {
  return JsonlFilesystemStreamStorage(
    applicationSupportDirectoryResolver: getApplicationSupportDirectory,
    namespaceDirectoryName: libraryJsonlStorageDirectoryName,
  );
}
