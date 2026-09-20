import '../../agents/jsonl/jsonl_stream_storage.dart';
import 'task_jsonl_storage_factory_unsupported.dart'
    if (dart.library.io) 'task_jsonl_storage_factory_io.dart'
    if (dart.library.js_interop) 'task_jsonl_storage_factory_web.dart'
    as platform;

JsonlStreamStorage createPlatformTaskJsonlStreamStorage() =>
    platform.createPlatformTaskJsonlStreamStorage();
