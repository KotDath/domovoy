import '../../agents/jsonl/jsonl_stream_storage.dart';

JsonlStreamStorage createPlatformMemoryJsonlStreamStorage() {
  throw UnsupportedError(
    'Durable memory storage is not available for this platform.',
  );
}
