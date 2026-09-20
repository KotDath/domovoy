import '../../agents/jsonl/jsonl_stream_storage.dart';
import 'jsonl_memory_storage_factory_unsupported.dart'
    if (dart.library.io) 'jsonl_memory_storage_factory_io.dart'
    if (dart.library.js_interop) 'jsonl_memory_storage_factory_web.dart'
    as platform;

/// Creates the durable storage selected for the current platform.
JsonlStreamStorage createPlatformMemoryJsonlStreamStorage() {
  return platform.createPlatformMemoryJsonlStreamStorage();
}
