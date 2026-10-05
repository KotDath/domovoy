import '../agents/jsonl/jsonl_stream_storage.dart';
import 'rag_storage_stub.dart'
    if (dart.library.io) 'rag_storage_io.dart'
    as platform;

JsonlStreamStorage? createRagStorage() => platform.createRagStorage();
JsonlStreamStorage? createRagTaskStateStorage() =>
    platform.createRagTaskStateStorage();
