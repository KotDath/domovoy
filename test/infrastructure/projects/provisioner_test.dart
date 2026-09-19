import 'dart:io';

import 'package:domovoy/core/llm/cancellation.dart';
import 'package:domovoy/core/projects/projects.dart';
import 'package:domovoy/infrastructure/projects/projects.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('desktop provisioners', () {
    test('linux attach then revalidate; path is not a grant', () async {
      final fs = FakeDesktopFilesystem(platformKind: ProjectPlatformKind.linux);
      fs.mount(components: ['home', 'work']);
      fs.bindHandle('h1', ['home', 'work']);
      final picker = ScriptedProjectDirectoryPicker()
        ..enqueue(
          const ProjectPickedDirectory(handleId: 'h1', safeLabel: 'work'),
        );
      final grants = InMemoryProjectDirectoryGrantStore();
      final provisioner = DesktopProjectRootProvisioner(
        capabilities: ProjectPlatformCapabilities.linux,
        filesystem: fs,
        picker: picker,
        grantStore: grants,
      );
      final staged = await provisioner.stageRoot(
        desktop: DesktopRootProvisionRequest(
          projectId: ProjectId('p1'),
          grantId: DirectoryGrantId('g1'),
          mode: ProjectDesktopRootMode.attachExisting,
          folderName: 'x',
        ),
        cancellation: CancellationSource().token,
      );
      expect(staged, isA<DesktopExternalRootResult>());
      await provisioner.acknowledgeRoot(staged);
      expect(
        await provisioner.revalidateRoot(
          grantId: DirectoryGrantId('g1'),
          projectId: ProjectId('p1'),
        ),
        ProjectAccessStatus.active,
      );
      expect(
        grants.debugOpaqueMaterial(DirectoryGrantId('g1')),
        isNot(contains('/home')),
      );
    });

    test('create collision does not adopt existing folder', () async {
      final fs = FakeDesktopFilesystem(platformKind: ProjectPlatformKind.linux);
      fs.mount(components: ['home', 'parent']);
      fs.mount(components: ['home', 'parent', 'taken']);
      final parent = fs.nodes.values.firstWhere(
        (node) => node.identity.components.join('/') == 'home/parent',
      );
      parent.children['taken'] = fs.nodes.values.firstWhere(
        (node) => node.identity.components.join('/') == 'home/parent/taken',
      );
      fs.bindHandle('parent', ['home', 'parent']);
      final picker = ScriptedProjectDirectoryPicker()
        ..enqueue(
          const ProjectPickedDirectory(handleId: 'parent', safeLabel: 'parent'),
        );
      final provisioner = DesktopProjectRootProvisioner(
        capabilities: ProjectPlatformCapabilities.linux,
        filesystem: fs,
        picker: picker,
        grantStore: InMemoryProjectDirectoryGrantStore(),
      );
      await expectLater(
        provisioner.stageRoot(
          desktop: DesktopRootProvisionRequest(
            projectId: ProjectId('p1'),
            grantId: DirectoryGrantId('g1'),
            mode: ProjectDesktopRootMode.createExclusive,
            folderName: 'taken',
          ),
          cancellation: CancellationSource().token,
        ),
        throwsA(
          isA<ProjectException>().having(
            (error) => error.error.kind,
            'kind',
            ProjectErrorKind.collision,
          ),
        ),
      );
    });

    test('windows rejects junction roots', () async {
      final fs = FakeDesktopFilesystem(
        platformKind: ProjectPlatformKind.windows,
      );
      fs.mount(components: ['Users', 'me'], volume: 'C:', isReparsePoint: true);
      fs.bindHandle('j', ['Users', 'me'], volume: 'C:');
      final picker = ScriptedProjectDirectoryPicker()
        ..enqueue(const ProjectPickedDirectory(handleId: 'j', safeLabel: 'me'));
      final provisioner = DesktopProjectRootProvisioner(
        capabilities: ProjectPlatformCapabilities.windows,
        filesystem: fs,
        picker: picker,
        grantStore: InMemoryProjectDirectoryGrantStore(),
      );
      await expectLater(
        provisioner.stageRoot(
          desktop: DesktopRootProvisionRequest(
            projectId: ProjectId('p1'),
            grantId: DirectoryGrantId('g1'),
            mode: ProjectDesktopRootMode.attachExisting,
            folderName: 'x',
          ),
          cancellation: CancellationSource().token,
        ),
        throwsA(isA<ProjectException>()),
      );
    });

    test(
      'macOS stale bookmark fails closed and path is insufficient',
      () async {
        final fs = FakeDesktopFilesystem(
          platformKind: ProjectPlatformKind.macos,
        );
        fs.mount(components: ['Users', 'me', 'proj']);
        fs.bindHandle('h', ['Users', 'me', 'proj']);
        final picker = ScriptedProjectDirectoryPicker()
          ..enqueue(
            const ProjectPickedDirectory(handleId: 'h', safeLabel: 'proj'),
          );
        final scope = FakeMacosSecurityScopeBroker();
        final grants = InMemoryProjectDirectoryGrantStore();
        final provisioner = DesktopProjectRootProvisioner(
          capabilities: ProjectPlatformCapabilities.macos,
          filesystem: fs,
          picker: picker,
          grantStore: grants,
          macosScope: scope,
        );
        final staged = await provisioner.stageRoot(
          desktop: DesktopRootProvisionRequest(
            projectId: ProjectId('p1'),
            grantId: DirectoryGrantId('g1'),
            mode: ProjectDesktopRootMode.attachExisting,
            folderName: 'x',
          ),
          cancellation: CancellationSource().token,
        );
        await provisioner.acknowledgeRoot(staged);
        final bookmark = scope.bookmarksByHandle['h']!;
        scope.stale.add(bookmark);
        expect(
          await provisioner.revalidateRoot(
            grantId: DirectoryGrantId('g1'),
            projectId: ProjectId('p1'),
          ),
          ProjectAccessStatus.requiresRegrant,
        );
        scope.stale.clear();
        scope.revoked.add(bookmark);
        expect(
          await provisioner.revalidateRoot(
            grantId: DirectoryGrantId('g1'),
            projectId: ProjectId('p1'),
          ),
          ProjectAccessStatus.revoked,
        );
        scope.available = false;
        expect(
          await provisioner.revalidateRoot(
            grantId: DirectoryGrantId('g1'),
            projectId: ProjectId('p1'),
          ),
          ProjectAccessStatus.unverifiable,
        );
      },
    );

    test('picker cancellation throws cancelled', () async {
      final provisioner = DesktopProjectRootProvisioner(
        capabilities: ProjectPlatformCapabilities.linux,
        filesystem: FakeDesktopFilesystem(
          platformKind: ProjectPlatformKind.linux,
        ),
        picker: ScriptedProjectDirectoryPicker()..enqueue(null),
        grantStore: InMemoryProjectDirectoryGrantStore(),
      );
      await expectLater(
        provisioner.stageRoot(
          desktop: DesktopRootProvisionRequest(
            projectId: ProjectId('p1'),
            grantId: DirectoryGrantId('g1'),
            mode: ProjectDesktopRootMode.attachExisting,
            folderName: 'x',
          ),
          cancellation: CancellationSource().token,
        ),
        throwsA(
          isA<ProjectException>().having(
            (error) => error.error.kind,
            'kind',
            ProjectErrorKind.cancelled,
          ),
        ),
      );
    });

    test(
      'revalidation preserves revoked status and rejects bindings',
      () async {
        final fs = FakeDesktopFilesystem(
          platformKind: ProjectPlatformKind.linux,
        );
        fs.mount(components: ['home', 'work']);
        final identity = fs.nodes.values.single.identity;
        final grants = InMemoryProjectDirectoryGrantStore();
        grants.seed(
          StagedDesktopGrant(
            descriptor: DesktopGrantDescriptor(
              grantId: DirectoryGrantId('g1'),
              projectId: ProjectId('other-project'),
              role: DirectoryGrantRole.root,
              requestedAccess: DirectoryGrantAccess.readWrite,
              origin: DirectoryGrantOrigin.attached,
              safeDisplayLabel: 'work',
              canonicalFingerprint: identity.fingerprint,
              platformKind: ProjectPlatformKind.linux,
              createdAtMicros: 1,
              updatedAtMicros: 1,
              status: ProjectAccessStatus.active,
            ),
            identity: identity,
            createdNewDirectory: false,
          ),
        );
        final provisioner = DesktopProjectRootProvisioner(
          capabilities: ProjectPlatformCapabilities.linux,
          filesystem: fs,
          picker: ScriptedProjectDirectoryPicker(),
          grantStore: grants,
        );
        expect(
          await provisioner.revalidateRoot(
            grantId: DirectoryGrantId('g1'),
            projectId: ProjectId('p1'),
          ),
          ProjectAccessStatus.unverifiable,
        );

        grants.revalidateStatus = ProjectAccessStatus.revoked;
        expect(
          await provisioner.revalidateRoot(
            grantId: DirectoryGrantId('g1'),
            projectId: ProjectId('other-project'),
          ),
          ProjectAccessStatus.revoked,
        );
      },
    );

    test('revalidation rejects a changed canonical target', () async {
      final fs = FakeDesktopFilesystem(platformKind: ProjectPlatformKind.linux);
      fs.mount(components: ['home', 'work']);
      final node = fs.nodes.values.single;
      final grants = InMemoryProjectDirectoryGrantStore();
      grants.seed(
        StagedDesktopGrant(
          descriptor: DesktopGrantDescriptor(
            grantId: DirectoryGrantId('g1'),
            projectId: ProjectId('p1'),
            role: DirectoryGrantRole.root,
            requestedAccess: DirectoryGrantAccess.readWrite,
            origin: DirectoryGrantOrigin.attached,
            safeDisplayLabel: 'work',
            canonicalFingerprint: node.identity.fingerprint,
            platformKind: ProjectPlatformKind.linux,
            createdAtMicros: 1,
            updatedAtMicros: 1,
            status: ProjectAccessStatus.active,
          ),
          identity: node.identity,
          createdNewDirectory: false,
        ),
      );
      node.target = CanonicalDirectoryIdentity(
        components: const ['home', 'replacement'],
        platformKind: ProjectPlatformKind.linux,
        fingerprint: fingerprintForComponents(const [
          'home',
          'replacement',
        ], platformKind: ProjectPlatformKind.linux),
      );
      final provisioner = DesktopProjectRootProvisioner(
        capabilities: ProjectPlatformCapabilities.linux,
        filesystem: fs,
        picker: ScriptedProjectDirectoryPicker(),
        grantStore: grants,
      );
      expect(
        await provisioner.revalidateRoot(
          grantId: DirectoryGrantId('g1'),
          projectId: ProjectId('p1'),
        ),
        ProjectAccessStatus.unverifiable,
      );
    });

    test('durable desktop grant revalidates after reconstruction', () async {
      final temporary = await Directory.systemTemp.createTemp(
        'domovoy-grant-restart-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final selected = Directory('${temporary.path}/selected');
      await selected.create();
      final support = Directory('${temporary.path}/support');
      final firstFilesystem = IoDesktopFilesystem(
        platformKind: ProjectPlatformKind.linux,
      );
      final identity = await firstFilesystem.canonicalize(selected.path);
      final firstStore = FileProjectDirectoryGrantStore(
        applicationSupportDirectoryResolver: () async => support,
        filesystem: firstFilesystem,
        platformKind: ProjectPlatformKind.linux,
      );
      await firstStore.acknowledge(
        StagedDesktopGrant(
          descriptor: DesktopGrantDescriptor(
            grantId: DirectoryGrantId('durable-g1'),
            projectId: ProjectId('durable-p1'),
            role: DirectoryGrantRole.root,
            requestedAccess: DirectoryGrantAccess.readWrite,
            origin: DirectoryGrantOrigin.attached,
            safeDisplayLabel: 'selected',
            canonicalFingerprint: identity.fingerprint,
            platformKind: ProjectPlatformKind.linux,
            createdAtMicros: 1,
            updatedAtMicros: 1,
            status: ProjectAccessStatus.missing,
          ),
          identity: identity,
          createdNewDirectory: false,
        ),
      );

      final reconstructedFilesystem = IoDesktopFilesystem(
        platformKind: ProjectPlatformKind.linux,
      );
      final reconstructedStore = FileProjectDirectoryGrantStore(
        applicationSupportDirectoryResolver: () async => support,
        filesystem: reconstructedFilesystem,
        platformKind: ProjectPlatformKind.linux,
      );
      final reconstructed = DesktopProjectRootProvisioner(
        capabilities: ProjectPlatformCapabilities.linux,
        filesystem: reconstructedFilesystem,
        picker: const NativeProjectDirectoryPicker(),
        grantStore: reconstructedStore,
      );
      expect(
        await reconstructed.revalidateRoot(
          grantId: DirectoryGrantId('durable-g1'),
          projectId: ProjectId('durable-p1'),
        ),
        ProjectAccessStatus.active,
      );
    });
  });

  group('mobile and web', () {
    test('android provisions identity-bound sandbox without picker', () async {
      final sandbox = FakeMobileSandbox(
        platformKind: ProjectPlatformKind.android,
      );
      final provisioner = MobileSandboxProjectRootProvisioner(
        capabilities: ProjectPlatformCapabilities.android,
        sandbox: sandbox,
      );
      final staged = await provisioner.stageRoot(
        mobile: MobileSandboxProvisionRequest(
          projectId: ProjectId('p1'),
          rootId: ProjectRootId('p1'),
        ),
        cancellation: CancellationSource().token,
      );
      expect(staged, isA<MobileSandboxRootResult>());
      expect(sandbox.pickerCalls, 0);
      expect(sandbox.grantStoreCalls, 0);
      sandbox.seedPreexisting(ProjectId('p2'));
      await expectLater(
        provisioner.stageRoot(
          mobile: MobileSandboxProvisionRequest(
            projectId: ProjectId('p2'),
            rootId: ProjectRootId('p2'),
          ),
          cancellation: CancellationSource().token,
        ),
        throwsA(isA<ProjectException>()),
      );
    });

    test('mobile sandbox is physically provisioned and restores', () async {
      final temporary = await Directory.systemTemp.createTemp(
        'domovoy-mobile-root-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final projectId = ProjectId('mobile-project');
      final first = MobileSandboxProjectRootProvisioner(
        capabilities: ProjectPlatformCapabilities.android,
        sandbox: IoMobileProjectSandbox(
          platformKind: ProjectPlatformKind.android,
          applicationSupportDirectoryResolver: () async => temporary,
        ),
      );
      await first.stageRoot(
        mobile: MobileSandboxProvisionRequest(
          projectId: projectId,
          rootId: ProjectRootId(projectId.value),
        ),
        cancellation: CancellationSource().token,
      );
      expect(
        Directory(
          '${temporary.path}/project-sandbox-roots-v1/${projectId.value}',
        ).existsSync(),
        isTrue,
      );
      final reconstructed = MobileSandboxProjectRootProvisioner(
        capabilities: ProjectPlatformCapabilities.android,
        sandbox: IoMobileProjectSandbox(
          platformKind: ProjectPlatformKind.android,
          applicationSupportDirectoryResolver: () async => temporary,
        ),
      );
      expect(
        await reconstructed.revalidateRoot(
          rootId: ProjectRootId(projectId.value),
          projectId: projectId,
        ),
        ProjectAccessStatus.active,
      );
    });

    test('web adapter writes nothing', () async {
      final provisioner = WebUnsupportedProjectRootProvisioner();
      final staged = await provisioner.stageRoot(
        cancellation: CancellationSource().token,
      );
      expect(staged, isA<UnsupportedRootResult>());
      expect(provisioner.writeCount, 0);
      expect(provisioner.grantStoreCalls, 0);
    });
  });
}
