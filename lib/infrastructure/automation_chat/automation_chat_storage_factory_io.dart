import 'package:path_provider/path_provider.dart';

import '../agents/jsonl/jsonl_stream_storage.dart';
import '../agents/jsonl/jsonl_stream_storage_io.dart';
import 'automation_chat_storage_namespace.dart';

JsonlStreamStorage? createPlatformAutomationChatJsonlStreamStorage() {
  return JsonlFilesystemStreamStorage(
    applicationSupportDirectoryResolver: getApplicationSupportDirectory,
    namespaceDirectoryName: automationChatJsonlStorageDirectoryName,
  );
}
