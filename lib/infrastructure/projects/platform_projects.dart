import 'platform_projects_stub.dart'
    if (dart.library.io) 'platform_projects_io.dart'
    if (dart.library.js_interop) 'platform_projects_web.dart'
    as platform;
import 'project_platform_stack.dart';

export 'project_platform_stack.dart';

ProjectPlatformStack createPlatformProjectStack() {
  return platform.createPlatformProjectStack();
}
