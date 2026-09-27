import '../agents/jsonl/jsonl_stream_storage.dart';
import 'automation_chat_storage_factory_unsupported.dart'
    if (dart.library.io) 'automation_chat_storage_factory_io.dart'
    if (dart.library.js_interop) 'automation_chat_storage_factory_web.dart'
    as platform;

/// Chat delivery cards use an independent on-device namespace.
///
/// Returns null on platforms without the native atomic-generation storage
/// (web and unknown targets): B9 must then compose the tasks feature without a
/// durable card store instead of inventing an ad hoc file path. The
/// composition never constructs a second card store.
JsonlStreamStorage? createPlatformAutomationChatJsonlStreamStorage() {
  return platform.createPlatformAutomationChatJsonlStreamStorage();
}
