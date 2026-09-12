import 'jsonl_stream_storage.dart';
import 'jsonl_stream_storage_factory_unsupported.dart'
    if (dart.library.io) 'jsonl_stream_storage_io.dart'
    if (dart.library.js_interop) 'jsonl_stream_storage_web.dart'
    as platform;

/// Creates the durable storage selected for the current platform.
JsonlStreamStorage createPlatformJsonlStreamStorage() {
  return platform.createPlatformJsonlStreamStorage();
}
