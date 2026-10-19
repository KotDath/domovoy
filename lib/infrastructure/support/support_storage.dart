import '../agents/jsonl/jsonl_stream_storage.dart';
import 'support_storage_stub.dart'
    if (dart.library.io) 'support_storage_io.dart'
    as platform;

JsonlStreamStorage? createSupportStorage() => platform.createSupportStorage();
JsonlStreamStorage? createSupportRagStorage() =>
    platform.createSupportRagStorage();
