import '../../agents/jsonl/jsonl_stream_storage.dart';
import '../../agents/jsonl/jsonl_stream_storage_web.dart';

const taskJsonlStorageNamespace = 'ru.kotdath.domovoy.task-workflows-jsonl-v1';

JsonlStreamStorage createPlatformTaskJsonlStreamStorage() =>
    JsonlBrowserStreamStorage(namespace: taskJsonlStorageNamespace);
