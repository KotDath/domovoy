import 'package:path_provider/path_provider.dart';
import 'jsonl_stream_storage.dart';
import 'jsonl_filesystem_storage_io.dart';
export 'jsonl_filesystem_storage_io.dart';

JsonlStreamStorage createPlatformJsonlStreamStorage() =>
    JsonlFilesystemStreamStorage(
      applicationSupportDirectoryResolver: getApplicationSupportDirectory,
    );
