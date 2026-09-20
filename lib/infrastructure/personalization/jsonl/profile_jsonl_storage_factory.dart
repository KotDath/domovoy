import '../../agents/jsonl/jsonl_stream_storage.dart';
import 'profile_jsonl_storage_factory_unsupported.dart'
    if (dart.library.io) 'profile_jsonl_storage_factory_io.dart'
    if (dart.library.js_interop) 'profile_jsonl_storage_factory_web.dart'
    as platform;

JsonlStreamStorage createPlatformProfileJsonlStreamStorage() =>
    platform.createPlatformProfileJsonlStreamStorage();
