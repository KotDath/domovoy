import 'jsonl_stream_storage.dart';

JsonlStreamStorage createPlatformJsonlStreamStorage() {
  throw UnsupportedError(
    'Durable JSONL storage is not available for this platform.',
  );
}
