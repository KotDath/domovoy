import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../core/projects/enums.dart';
import '../../core/projects/provisioning.dart';
import '../agents/jsonl/jsonl_stream_storage_io.dart';
import 'fs/desktop_filesystem.dart';
import 'grants/file_grant_store.dart';
import 'grants/macos_security_scope.dart';
import 'jsonl/jsonl_project_store.dart';
import 'project_platform_stack.dart';
import 'provisioners/desktop_root_provisioner.dart';
import 'provisioners/mobile_sandbox_provisioner.dart';
import 'provisioners/scripted_picker.dart';
import 'provisioners/web_unsupported_provisioner.dart';

ProjectPlatformStack createPlatformProjectStack() {
  final storage = JsonlFilesystemStreamStorage(
    applicationSupportDirectoryResolver: getApplicationSupportDirectory,
    namespaceDirectoryName:
        JsonlFilesystemStreamStorage.projectStorageDirectoryName,
  );
  final store = JsonlProjectStore(storage: storage);
  if (Platform.isAndroid ||
      Platform.isIOS ||
      Platform.operatingSystem == 'aurora') {
    final kind = Platform.isIOS
        ? ProjectPlatformKind.ios
        : Platform.operatingSystem == 'aurora'
        ? ProjectPlatformKind.aurora
        : ProjectPlatformKind.android;
    return ProjectPlatformStack(
      repository: store,
      catalog: store,
      provisioner: MobileSandboxProjectRootProvisioner(
        capabilities: kind == ProjectPlatformKind.ios
            ? ProjectPlatformCapabilities.ios
            : kind == ProjectPlatformKind.aurora
            ? ProjectPlatformCapabilities.aurora
            : ProjectPlatformCapabilities.android,
        sandbox: IoMobileProjectSandbox(
          platformKind: kind,
          applicationSupportDirectoryResolver: getApplicationSupportDirectory,
        ),
      ),
    );
  }
  if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
    final capabilities = Platform.isMacOS
        ? ProjectPlatformCapabilities.macos
        : Platform.isWindows
        ? ProjectPlatformCapabilities.windows
        : ProjectPlatformCapabilities.linux;
    final filesystem = IoDesktopFilesystem(
      platformKind: capabilities.platformKind,
    );
    final scope = Platform.isMacOS
        ? MethodChannelMacosSecurityScopeBroker()
        : null;
    final grants = FileProjectDirectoryGrantStore(
      applicationSupportDirectoryResolver: getApplicationSupportDirectory,
      filesystem: filesystem,
      platformKind: capabilities.platformKind,
      macosScope: scope,
    );
    return ProjectPlatformStack(
      repository: store,
      catalog: store,
      grants: grants,
      provisioner: DesktopProjectRootProvisioner(
        capabilities: capabilities,
        filesystem: filesystem,
        picker: const NativeProjectDirectoryPicker(),
        grantStore: grants,
        sandbox: IoMobileProjectSandbox(
          platformKind: capabilities.platformKind,
          applicationSupportDirectoryResolver: getApplicationSupportDirectory,
        ),
        macosScope: scope,
      ),
    );
  }
  return ProjectPlatformStack(
    repository: store,
    catalog: store,
    provisioner: WebUnsupportedProjectRootProvisioner(),
  );
}
