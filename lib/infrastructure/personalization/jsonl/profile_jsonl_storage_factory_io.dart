import 'package:path_provider/path_provider.dart';

import '../../agents/jsonl/jsonl_stream_storage.dart';
import '../../agents/jsonl/jsonl_stream_storage_io.dart';

const profileJsonlStorageDirectoryName = 'personalization-jsonl-v1';

JsonlStreamStorage createPlatformProfileJsonlStreamStorage() =>
    JsonlFilesystemStreamStorage(
      applicationSupportDirectoryResolver: getApplicationSupportDirectory,
      namespaceDirectoryName: profileJsonlStorageDirectoryName,
    );
