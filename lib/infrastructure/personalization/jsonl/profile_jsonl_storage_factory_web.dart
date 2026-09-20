import '../../agents/jsonl/jsonl_stream_storage.dart';
import '../../agents/jsonl/jsonl_stream_storage_web.dart';

const profileJsonlBrowserNamespace =
    'ru.kotdath.domovoy.personalization-jsonl-v1';

JsonlStreamStorage createPlatformProfileJsonlStreamStorage() =>
    JsonlBrowserStreamStorage(namespace: profileJsonlBrowserNamespace);
