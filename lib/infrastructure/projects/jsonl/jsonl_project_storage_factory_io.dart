import 'package:path_provider/path_provider.dart';

import '../../agents/jsonl/jsonl_stream_storage.dart';
import '../../agents/jsonl/jsonl_stream_storage_io.dart';

JsonlStreamStorage? createPlatformProjectJsonlStreamStorage() {
  return JsonlFilesystemStreamStorage(
    applicationSupportDirectoryResolver: getApplicationSupportDirectory,
    namespaceDirectoryName:
        JsonlFilesystemStreamStorage.projectStorageDirectoryName,
  );
}
