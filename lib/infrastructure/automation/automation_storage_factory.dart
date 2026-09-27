import '../agents/jsonl/jsonl_stream_storage.dart';
import 'automation_storage_factory_unsupported.dart'
    if (dart.library.io) 'automation_storage_factory_io.dart'
    if (dart.library.js_interop) 'automation_storage_factory_web.dart'
    as platform;

/// Automation JSONL streams use an independent on-device namespace.
///
/// Returns null on platforms without the native atomic-generation storage
/// (web and unknown targets): B9 must then leave the scheduler without durable
/// storage instead of inventing an ad hoc file path. The composition never
/// constructs a second automation store.
JsonlStreamStorage? createPlatformAutomationJsonlStreamStorage() {
  return platform.createPlatformAutomationJsonlStreamStorage();
}
