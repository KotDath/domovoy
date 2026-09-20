import 'package:path_provider/path_provider.dart';

import '../../agents/jsonl/jsonl_stream_storage.dart';
import '../../agents/jsonl/jsonl_stream_storage_io.dart';

const taskJsonlStorageDirectoryName = 'task-workflows-jsonl-v1';

JsonlStreamStorage createPlatformTaskJsonlStreamStorage() =>
    JsonlFilesystemStreamStorage(
      applicationSupportDirectoryResolver: getApplicationSupportDirectory,
      namespaceDirectoryName: taskJsonlStorageDirectoryName,
    );
