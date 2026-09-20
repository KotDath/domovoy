import '../../agents/jsonl/jsonl_stream_storage.dart';
import '../../agents/jsonl/jsonl_stream_storage_web.dart';

/// Browser memory streams use an independent origin-local namespace.
const memoryJsonlBrowserNamespace = 'ru.kotdath.domovoy.memory-jsonl-v1';

JsonlStreamStorage createPlatformMemoryJsonlStreamStorage() {
  return JsonlBrowserStreamStorage(namespace: memoryJsonlBrowserNamespace);
}
