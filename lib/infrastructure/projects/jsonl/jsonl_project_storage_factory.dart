import '../../agents/jsonl/jsonl_stream_storage.dart';
import 'jsonl_project_storage_factory_unsupported.dart'
    if (dart.library.io) 'jsonl_project_storage_factory_io.dart'
    if (dart.library.js_interop) 'jsonl_project_storage_factory_web.dart'
    as platform;

/// Native Project streams use an independent namespace. Web returns null.
JsonlStreamStorage? createPlatformProjectJsonlStreamStorage() {
  return platform.createPlatformProjectJsonlStreamStorage();
}
