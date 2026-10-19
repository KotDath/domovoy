import 'package:path_provider/path_provider.dart';
import '../agents/jsonl/jsonl_stream_storage.dart';
import '../agents/jsonl/jsonl_stream_storage_io.dart';

JsonlStreamStorage createSupportStorage() => JsonlFilesystemStreamStorage(
  applicationSupportDirectoryResolver: getApplicationSupportDirectory,
  namespaceDirectoryName: 'product-support-jsonl-v1',
);
JsonlStreamStorage createSupportRagStorage() => JsonlFilesystemStreamStorage(
  applicationSupportDirectoryResolver: getApplicationSupportDirectory,
  namespaceDirectoryName: 'product-support-rag-jsonl-v1',
);
