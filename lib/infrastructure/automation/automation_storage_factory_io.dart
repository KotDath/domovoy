import 'package:path_provider/path_provider.dart';

import '../agents/jsonl/jsonl_stream_storage.dart';
import '../agents/jsonl/jsonl_stream_storage_io.dart';
import 'automation_storage_namespace.dart';

JsonlStreamStorage? createPlatformAutomationJsonlStreamStorage() {
  return JsonlFilesystemStreamStorage(
    applicationSupportDirectoryResolver: getApplicationSupportDirectory,
    namespaceDirectoryName: automationJsonlStorageDirectoryName,
  );
}
