import '../../../agents/jsonl/jsonl_stream_storage.dart';
import 'library_storage_factory_unsupported.dart'
    if (dart.library.io) 'library_storage_factory_io.dart'
    if (dart.library.js_interop) 'library_storage_factory_web.dart'
    as platform;

/// Library JSONL streams use an independent on-device namespace.
///
/// Returns null on platforms without the native atomic-generation storage
/// (web and unknown targets): B9 must then leave the `library` server
/// unregistered instead of inventing an ad hoc file path. The composition
/// never constructs a second library store.
JsonlStreamStorage? createPlatformLibraryJsonlStreamStorage() {
  return platform.createPlatformLibraryJsonlStreamStorage();
}
