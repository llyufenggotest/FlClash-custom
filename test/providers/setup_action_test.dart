import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/core/rule_generation_preparation.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:riverpod/riverpod.dart';

import '../helpers/test_profiles.dart';

class _MockCoreHandlerInterface extends Mock implements CoreHandlerInterface {}

// checkAndUpdateAndCopy checks the file system before it refreshes, so its
// failure tests need appPath to resolve to a real, writable directory.
class _FakePathProvider extends PathProviderPlatform {
  final String root;

  _FakePathProvider(this.root);

  @override
  Future<String?> getTemporaryPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => root;
}

class _ListenerHandoffFailureSetupAction extends SetupAction {
  final List<bool> coreRunningCalls = [];

  @override
  Future<bool> setCoreRunning(bool running) async {
    coreRunningCalls.add(running);
    if (running) {
      throw StateError('listener handoff failed');
    }
    return true;
  }
}

class _MessageFailureSetupAction extends SetupAction {
  final List<bool> coreRunningCalls = [];

  @override
  Future<bool> setCoreRunning(bool running) async {
    coreRunningCalls.add(running);
    return true;
  }
}

class TestCommonAction extends CommonAction {
  int trafficUpdates = 0;

  @override
  Future<void> updateTraffic() async {
    trafficUpdates++;
  }
}

class _ControlledPrewarmSetupAction extends SetupAction {
  final List<int> started = [];
  final List<int> finished = [];
  final Map<int, Completer<void>> releases = {};
  int active = 0;
  int maxActive = 0;

  @override
  Future<RuleGenerationPreparation?> prewarmProfile(
    Profile profile, {
    String? candidateYaml,
    bool allowUncommittedProfile = false,
  }) async {
    started.add(profile.id);
    active++;
    if (active > maxActive) maxActive = active;
    final release = releases.putIfAbsent(profile.id, Completer<void>.new);
    await release.future;
    active--;
    finished.add(profile.id);
    return null;
  }
}

class _VersionedPrewarmSetupAction extends SetupAction {
  final List<DateTime?> started = [];
  final List<Completer<void>> releases = [];
  int active = 0;
  int maxActive = 0;

  @override
  Future<RuleGenerationPreparation?> prewarmProfile(
    Profile profile, {
    String? candidateYaml,
    bool allowUncommittedProfile = false,
  }) async {
    started.add(profile.lastUpdateDate);
    active++;
    if (active > maxActive) maxActive = active;
    final release = Completer<void>();
    releases.add(release);
    await release.future;
    active--;
    return null;
  }
}

class TestSetupAction extends SetupAction {
  final List<bool> coreRunningCalls = [];
  final List<Completer<void>> pendingCoreCalls = [];
  int trafficResets = 0;
  int applyProfileCalls = 0;
  bool blockCoreCalls = false;
  Error? coreRunningError;
  int authorizeCalls = 0;
  AuthorizeCode authorizeResult = AuthorizeCode.none;
  bool restoreServiceRunTime = false;
  DateTime? serviceRunTime;
  int serviceRunTimeReads = 0;

  @override
  bool get shouldRestoreServiceRunTime => restoreServiceRunTime;

  @override
  Future<DateTime?> readServiceRunTime() async {
    serviceRunTimeReads++;
    return serviceRunTime;
  }

  @override
  Future<AuthorizeCode> authorizeCore() async {
    authorizeCalls++;
    return authorizeResult;
  }

  @override
  Future<bool> setCoreRunning(bool running) async {
    coreRunningCalls.add(running);
    if (blockCoreCalls) {
      final gate = Completer<void>();
      pendingCoreCalls.add(gate);
      await gate.future;
    }
    final error = coreRunningError;
    if (error != null) {
      throw error;
    }
    return true;
  }

  @override
  void resetCoreTraffic() => trafficResets++;

  @override
  Future<bool> applyProfile({
    bool silence = false,
    bool force = false,
    bool profileSwitched = false,
    bool allowRuleGenerationPreparation = false,
    bool Function()? activationGuard,
    Future<void> Function()? preloadInvoke,
    ProfileSwitchPhaseTimer? timing,
  }) async {
    applyProfileCalls++;
    await preloadInvoke?.call();
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    registerFallbackValue(const SetupParams(selectedMap: {}, testUrl: ''));
  });

  late TestSetupAction action;
  late ProviderContainer container;

  setUp(() {
    action = TestSetupAction();
    container = ProviderContainer(
      overrides: [
        profilesProvider.overrideWith(TestProfiles.new),
        setupActionProvider.overrideWith(() => action),
        commonActionProvider.overrideWith(TestCommonAction.new),
      ],
    );
    globalState.container = container;
    globalState.needInitStatus = true;
    container.read(setupActionProvider.notifier);
  });

  tearDown(() async {
    action.blockCoreCalls = false;
    action.coreRunningError = null;
    for (final gate in action.pendingCoreCalls) {
      if (!gate.isCompleted) {
        gate.complete();
      }
    }
    await container.read(setupActionProvider.notifier).setRunning(false);
    container.dispose();
    globalState.needInitStatus = true;
  });

  void markInitialized() {
    container.read(initProvider.notifier).value = true;
  }

  group('profile prewarm scheduling', () {
    test(
      'deduplicates one profile and serializes different profiles',
      () async {
        final first = Profile.normal(label: 'first');
        final second = Profile.normal(label: 'second');
        final scoped = ProviderContainer(
          overrides: [
            profilesProvider.overrideWith(() => TestProfiles([first, second])),
            setupActionProvider.overrideWith(_ControlledPrewarmSetupAction.new),
          ],
        );
        addTearDown(scoped.dispose);
        final prewarm =
            scoped.read(setupActionProvider.notifier)
                as _ControlledPrewarmSetupAction;

        final firstFlight = prewarm.scheduleProfilePrewarm(first);
        final duplicateFlight = prewarm.scheduleProfilePrewarm(first);
        final secondFlight = prewarm.scheduleProfilePrewarm(second);
        await Future<void>.delayed(Duration.zero);

        expect(identical(firstFlight, duplicateFlight), isTrue);
        expect(prewarm.started, [first.id]);
        expect(prewarm.active, 1);
        expect(prewarm.maxActive, 1);

        prewarm.releases[first.id]!.complete();
        await firstFlight;
        await Future<void>.delayed(Duration.zero);

        expect(prewarm.started, [first.id, second.id]);
        expect(prewarm.finished, [first.id]);
        expect(prewarm.active, 1);
        expect(prewarm.maxActive, 1);

        prewarm.releases[second.id]!.complete();
        await secondFlight;
        expect(prewarm.finished, [first.id, second.id]);
        expect(prewarm.maxActive, 1);
      },
    );

    test(
      'queues revision requests and resolves each against the latest persisted profile',
      () async {
        final firstUpdated = DateTime.fromMillisecondsSinceEpoch(1000);
        final secondUpdated = DateTime.fromMillisecondsSinceEpoch(2000);
        final first = Profile.normal(
          label: 'profile',
        ).copyWith(lastUpdateDate: firstUpdated);
        final second = first.copyWith(lastUpdateDate: secondUpdated);
        final scoped = ProviderContainer(
          overrides: [
            profilesProvider.overrideWith(() => TestProfiles([second])),
            setupActionProvider.overrideWith(_VersionedPrewarmSetupAction.new),
          ],
        );
        addTearDown(scoped.dispose);
        final prewarm =
            scoped.read(setupActionProvider.notifier)
                as _VersionedPrewarmSetupAction;

        final firstFlight = prewarm.scheduleProfilePrewarm(first);
        await Future<void>.delayed(Duration.zero);
        final secondFlight = prewarm.scheduleProfilePrewarm(second);
        await Future<void>.delayed(Duration.zero);

        expect(identical(firstFlight, secondFlight), isFalse);
        expect(prewarm.started, [secondUpdated]);
        expect(prewarm.maxActive, 1);

        prewarm.releases.single.complete();
        await firstFlight;
        await Future<void>.delayed(Duration.zero);
        expect(prewarm.started, [secondUpdated, secondUpdated]);
        expect(prewarm.maxActive, 1);

        prewarm.releases.last.complete();
        await secondFlight;
      },
    );
  });

  group('rule preparation progress provider', () {
    test('publishes and clears progress by operation', () {
      const first = RulePreparationProgress(
        profileId: 1,
        operationId: 'first',
        phase: RulePreparationPhase.downloading,
        kind: 'rule-provider',
        name: 'ads',
        path: '/rules/ads.yaml',
      );
      const second = RulePreparationProgress(
        profileId: 1,
        operationId: 'second',
        phase: RulePreparationPhase.validating,
        kind: 'rule-provider',
        name: 'private',
        path: '/rules/private.yaml',
      );
      final notifier = container.read(rulePreparationProgressProvider.notifier);

      notifier.update(first);
      notifier.update(second);
      final progress = container.read(rulePreparationProgressProvider);
      expect(progress.keys, {first.key, second.key});
      expect(progress[first.key], same(first));
      expect(progress[second.key], same(second));

      notifier.clear(key: first.key);
      final remaining = container.read(rulePreparationProgressProvider);
      expect(remaining.keys, {second.key});
      expect(remaining[second.key], same(second));

      notifier.clear(profileId: second.profileId);
      expect(container.read(rulePreparationProgressProvider), isEmpty);
    });
  });

  group('setRunning gating', () {
    test('ignores a start request before initialization completes', () async {
      await container.read(setupActionProvider.notifier).setRunning(true);

      expect(action.coreRunningCalls, isEmpty);
      expect(container.read(runTimeProvider), isNull);
    });

    test('an initialize request bypasses the init gate', () async {
      await container
          .read(setupActionProvider.notifier)
          .setRunning(true, initialize: true);

      expect(action.coreRunningCalls, [true]);
      expect(action.applyProfileCalls, 1);
      expect(globalState.needInitStatus, isFalse);
    });

    test('starts the core once initialization is done', () async {
      markInitialized();

      await container.read(setupActionProvider.notifier).setRunning(true);

      expect(action.coreRunningCalls, [true]);
      expect(container.read(runTimeProvider), isNotNull);
    });

    test('a stop request is never gated on initialization', () async {
      await container.read(setupActionProvider.notifier).setRunning(false);

      expect(action.coreRunningCalls, [false]);
    });
  });

  group('run failures', () {
    test('a start the core rejects stops reporting a run time', () async {
      markInitialized();
      action.coreRunningError = StateError('start failed');

      await expectLater(
        container.read(setupActionProvider.notifier).setRunning(true),
        throwsStateError,
      );

      expect(container.read(runTimeProvider), isNull);
    });

    test(
      'a stop the core rejects keeps the run time it started with',
      () async {
        markInitialized();
        await container.read(setupActionProvider.notifier).setRunning(true);
        action.coreRunningError = StateError('stop failed');

        await expectLater(
          container.read(setupActionProvider.notifier).setRunning(false),
          throwsStateError,
        );

        expect(container.read(runTimeProvider), isNotNull);
      },
    );
  });

  group('stop cleanup', () {
    test('resets traffic counters and re-checks the ip', () async {
      markInitialized();
      await container.read(setupActionProvider.notifier).setRunning(true);
      container.read(totalTrafficProvider.notifier).value = const Traffic(
        up: 10,
        down: 20,
      );
      final checkIpBefore = container.read(checkIpNumProvider);

      await container.read(setupActionProvider.notifier).setRunning(false);

      expect(action.trafficResets, 1);
      expect(container.read(trafficsProvider).list, isEmpty);
      expect(container.read(totalTrafficProvider), const Traffic());
      expect(container.read(checkIpNumProvider), checkIpBefore + 1);
      expect(container.read(runTimeProvider), isNull);
    });
  });

  group('suspend', () {
    test('skips starting the core on an excluded SSID', () async {
      container.dispose();
      action = TestSetupAction();
      container = ProviderContainer(
        overrides: [
          profilesProvider.overrideWith(TestProfiles.new),
          setupActionProvider.overrideWith(() => action),
          commonActionProvider.overrideWith(TestCommonAction.new),
          excludeSSIDsProvider.overrideWithValue(const ['Office Wi-Fi']),
        ],
      );
      globalState.container = container;
      container.read(initProvider.notifier).value = true;
      container.read(currentSSIDProvider.notifier).value = 'Office Wi-Fi';

      await container.read(setupActionProvider.notifier).setRunning(true);

      expect(action.coreRunningCalls, isEmpty);
    });

    test('still stops the core on an excluded SSID', () async {
      container.dispose();
      action = TestSetupAction();
      container = ProviderContainer(
        overrides: [
          profilesProvider.overrideWith(TestProfiles.new),
          setupActionProvider.overrideWith(() => action),
          commonActionProvider.overrideWith(TestCommonAction.new),
          excludeSSIDsProvider.overrideWithValue(const ['Office Wi-Fi']),
        ],
      );
      globalState.container = container;
      container.read(currentSSIDProvider.notifier).value = 'Office Wi-Fi';

      await container.read(setupActionProvider.notifier).setRunning(false);

      expect(action.coreRunningCalls, [false]);
    });
  });

  group('latest-intent arbitration', () {
    test('a superseded stop does not run the post-stop cleanup', () async {
      markInitialized();
      final notifier = container.read(setupActionProvider.notifier);
      action.blockCoreCalls = true;

      final stopping = notifier.setRunning(false);
      await Future<void>.delayed(Duration.zero);
      final starting = notifier.setRunning(true);
      await Future<void>.delayed(Duration.zero);

      action.blockCoreCalls = false;
      for (final gate in action.pendingCoreCalls) {
        if (!gate.isCompleted) {
          gate.complete();
        }
      }
      await Future.wait([stopping, starting]);

      expect(action.coreRunningCalls, [false, true]);
      expect(action.trafficResets, 0);
      expect(container.read(runTimeProvider), isNotNull);
    });

    test('the newest request wins the local running state', () async {
      markInitialized();
      final notifier = container.read(setupActionProvider.notifier);

      await notifier.setRunning(true);
      expect(container.read(runTimeProvider), isNotNull);

      await notifier.setRunning(false);
      expect(container.read(runTimeProvider), isNull);

      await notifier.setRunning(true);
      expect(container.read(runTimeProvider), isNotNull);
      expect(action.coreRunningCalls, [true, false, true]);
    });
  });

  group('initStatus', () {
    test('is a no-op once the status has already been initialized', () async {
      globalState.needInitStatus = false;

      await container.read(setupActionProvider.notifier).initStatus();

      expect(action.coreRunningCalls, isEmpty);
      expect(action.applyProfileCalls, 0);
    });

    test('starts the core when autoRun is enabled', () async {
      container.read(appSettingProvider.notifier).value = const AppSettingProps(
        autoRun: true,
      );

      await container.read(setupActionProvider.notifier).initStatus();

      expect(action.coreRunningCalls, [true]);
      expect(globalState.needInitStatus, isFalse);
    });

    test('restores a running mobile service before applying autoRun', () async {
      action.restoreServiceRunTime = true;
      action.serviceRunTime = DateTime.now().subtract(
        const Duration(minutes: 1),
      );

      await container.read(setupActionProvider.notifier).initStatus();

      expect(action.serviceRunTimeReads, 1);
      expect(action.coreRunningCalls, [true]);
      expect(container.read(runTimeProvider), isNotNull);
    });

    test('only applies the profile when autoRun is disabled', () async {
      container.read(appSettingProvider.notifier).value = const AppSettingProps(
        autoRun: false,
      );

      await container.read(setupActionProvider.notifier).initStatus();

      expect(action.coreRunningCalls, isEmpty);
      expect(action.applyProfileCalls, 1);
    });
  });

  group('requestAdmin', () {
    test('never asks for authorization while tun is disabled', () async {
      expect(await action.requestAdmin(false), isTrue);

      expect(action.authorizeCalls, 0);
      expect(
        container.read(authorizedTunEnableProvider),
        TunAuthorizationState.none,
      );
    });

    test('does not ask again once the state left none', () async {
      container.read(authorizedTunEnableProvider.notifier).value =
          TunAuthorizationState.authorized;

      expect(await action.requestAdmin(true), isTrue);
      expect(action.authorizeCalls, 0);
    });

    test(
      'a successful authorization hands off instead of continuing',
      () async {
        action.authorizeResult = AuthorizeCode.success;

        expect(await action.requestAdmin(true), isFalse);
        expect(action.authorizeCalls, 1);
        expect(
          container.read(authorizedTunEnableProvider),
          TunAuthorizationState.authorized,
        );
      },
    );

    test('a platform without an authorization step continues inline', () async {
      action.authorizeResult = AuthorizeCode.none;

      expect(await action.requestAdmin(true), isTrue);
      expect(
        container.read(authorizedTunEnableProvider),
        TunAuthorizationState.authorized,
      );
    });

    test('a failed authorization continues but stays unauthorized', () async {
      action.authorizeResult = AuthorizeCode.error;

      expect(await action.requestAdmin(true), isTrue);
      expect(
        container.read(authorizedTunEnableProvider),
        TunAuthorizationState.unauthorized,
      );
    });
  });

  group('recoverMissingProfile', () {
    ProviderContainer buildScoped(List<Profile> profiles, int? profileId) {
      final scoped = ProviderContainer(
        overrides: [
          profilesProvider.overrideWith(() => TestProfiles(profiles)),
          currentProfileIdProvider.overrideWithBuild((_, _) => profileId),
          setupActionProvider.overrideWith(TestSetupAction.new),
        ],
      );
      addTearDown(scoped.dispose);
      return scoped;
    }

    test('a dangling profile id falls back to the first profile', () {
      final profile = Profile.normal(label: 'p').copyWith(id: 1);
      final scoped = buildScoped([profile], 404);

      final recovered = scoped
          .read(setupActionProvider.notifier)
          .recoverMissingProfile();

      expect(recovered?.id, profile.id);
      expect(scoped.read(currentProfileIdProvider), profile.id);
    });

    test('no profiles keeps the stored id untouched', () {
      final scoped = buildScoped(const [], 404);

      expect(
        scoped.read(setupActionProvider.notifier).recoverMissingProfile(),
        isNull,
      );
      expect(scoped.read(currentProfileIdProvider), 404);
    });

    test('an unset id is the first-run state, not a dangling one', () {
      final profile = Profile.normal(label: 'p').copyWith(id: 1);
      final scoped = buildScoped([profile], null);

      expect(
        scoped.read(setupActionProvider.notifier).recoverMissingProfile(),
        isNull,
      );
      expect(scoped.read(currentProfileIdProvider), isNull);
    });
  });

  group('changeMode', () {
    test('records the requested mode', () {
      container.read(setupActionProvider.notifier).changeMode(Mode.direct);

      expect(container.read(patchClashConfigProvider).mode, Mode.direct);
    });

    test('leaving global alone keeps the selected group', () {
      final profile = Profile.normal(
        label: 'p',
      ).copyWith(id: 1, currentGroupName: 'Manual');
      final scoped = ProviderContainer(
        overrides: [
          profilesProvider.overrideWith(() => TestProfiles([profile])),
          currentProfileIdProvider.overrideWithBuild((_, _) => profile.id),
          setupActionProvider.overrideWith(TestSetupAction.new),
        ],
      );
      addTearDown(scoped.dispose);

      scoped.read(setupActionProvider.notifier).changeMode(Mode.rule);

      expect(scoped.read(currentProfileProvider)?.currentGroupName, 'Manual');
    });

    test('global mode also selects the global group', () {
      final profile = Profile.normal(
        label: 'p',
      ).copyWith(id: 1, currentGroupName: 'Manual');
      final scoped = ProviderContainer(
        overrides: [
          profilesProvider.overrideWith(() => TestProfiles([profile])),
          currentProfileIdProvider.overrideWithBuild((_, _) => profile.id),
          setupActionProvider.overrideWith(TestSetupAction.new),
        ],
      );
      addTearDown(scoped.dispose);

      scoped.read(setupActionProvider.notifier).changeMode(Mode.global);

      expect(scoped.read(patchClashConfigProvider).mode, Mode.global);
      expect(
        scoped.read(currentProfileProvider)?.currentGroupName,
        GroupName.GLOBAL.name,
      );
    });
  });

  group('applyProfileDebounce', () {
    test('collapses a burst into a single apply', () async {
      final notifier = container.read(setupActionProvider.notifier);

      notifier.applyProfileDebounce(force: true);
      notifier.applyProfileDebounce(force: true);
      notifier.applyProfileDebounce(force: true);
      expect(action.applyProfileCalls, 0);

      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(action.applyProfileCalls, 1);
    });

    test('a stop cancels a pending apply', () async {
      markInitialized();
      final notifier = container.read(setupActionProvider.notifier);

      notifier.applyProfileDebounce(force: true);
      await notifier.setRunning(false);

      await Future<void>.delayed(const Duration(milliseconds: 800));
      expect(action.applyProfileCalls, 0);
    });
  });

  group('_setupConfig via the real SetupAction', () {
    late Directory tempDir;
    late String? originalLastConfigMd5;

    setUpAll(() async {
      tempDir = Directory.systemTemp.createTempSync('setup_action_test');
      PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
      await AppLocalizations.load(const Locale('en'));
      globalState.packageInfo = PackageInfo(
        appName: 'FlClash',
        packageName: 'com.follow.clash',
        version: '0.0.0',
        buildNumber: '0',
      );
      originalLastConfigMd5 = globalState.lastConfigMd5;
    });

    tearDownAll(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    tearDown(() {
      globalState.lastConfigMd5 = originalLastConfigMd5;
    });

    // profileId: null routes getProfile/setupState around the database and
    // Core.getConfig, isolating the behavior under test.
    const nullProfileSetupState = SetupState(
      profileId: null,
      profileLastUpdateDate: null,
      overwriteType: OverwriteType.standard,
      rules: [],
      proxyGroups: [],
      addedRules: [],
      script: null,
      overrideDns: false,
      dns: Dns(),
    );

    test(
      'a refresh failure keeps the cached profile and still configures core',
      () async {
        final profile = Profile.normal(
          label: 'p',
          url: 'http://cached.invalid/profile',
        );
        final cachedPath = await appPath.getProfilePath(profile.id.toString());
        final cachedFile = File(cachedPath);
        await cachedFile.parent.create(recursive: true);
        await cachedFile.writeAsString('proxies: []\nrules: []\n', flush: true);
        final core = _MockCoreHandlerInterface();
        when(() => core.setupConfig(any())).thenAnswer((_) async => '');
        var preloadRan = false;
        final scoped = ProviderContainer(
          overrides: [
            profilesProvider.overrideWith(() => TestProfiles([profile])),
            currentProfileIdProvider.overrideWithBuild((_, _) => profile.id),
            setupStateProvider.overrideWith((_, _) => nullProfileSetupState),
            coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
            setupActionProvider.overrideWith(SetupAction.new),
          ],
        );
        addTearDown(scoped.dispose);

        await scoped
            .read(setupActionProvider.notifier)
            .applyProfile(
              force: true,
              preloadInvoke: () async {
                preloadRan = true;
              },
            );

        expect(preloadRan, isTrue);
        verify(() => core.setupConfig(any())).called(1);
      },
    );

    test(
      'a switch consumes its matching prepared generation without prewarming',
      () async {
        final profile = Profile.normal(label: 'switched');
        final core = _MockCoreHandlerInterface();
        when(core.cancelDelayTests).thenAnswer((_) async => true);
        when(
          () => core.setProfileSwitchProbeBarrier(
            token: any(named: 'token'),
            suspended: any(named: 'suspended'),
          ),
        ).thenAnswer((_) async => true);
        when(() => core.getProfileConfig(profile.id)).thenAnswer(
          (_) async => <String, dynamic>{
            'proxies': [
              {
                'name': 'New node',
                'type': 'ss',
                'server': '127.0.0.1',
                'port': 443,
                'cipher': 'aes-128-gcm',
                'password': 'test',
              },
            ],
            'proxy-groups': [
              {
                'name': 'Proxy',
                'type': 'select',
                'proxies': ['New node'],
              },
            ],
            'proxy-providers': {
              'remote': {
                'type': 'http',
                'url': 'https://provider.invalid/proxies.yaml',
                'interval': 86400,
              },
            },
            'rules': ['MATCH,Proxy'],
          },
        );
        when(() => core.setupConfig(any())).thenAnswer((_) async => '');
        when(() => core.getProxies()).thenAnswer(
          (_) async => const ProxiesData(
            all: ['Proxy', 'New node'],
            proxies: {
              'Proxy': {
                'name': 'Proxy',
                'type': 'Selector',
                'now': 'New node',
                'all': ['New node'],
              },
              'New node': {'name': 'New node', 'type': 'ss'},
            },
          ),
        );
        when(
          () => core.getExternalProviders(),
        ).thenAnswer((_) async => const []);
        final scoped = ProviderContainer(
          overrides: [
            initProvider.overrideWithBuild((_, _) => true),
            profilesProvider.overrideWith(() => TestProfiles([profile])),
            currentProfileIdProvider.overrideWithBuild((_, _) => profile.id),
            setupStateProvider.overrideWith(
              (_, profileId) =>
                  nullProfileSetupState.copyWith(profileId: profileId),
            ),
            coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
            setupActionProvider.overrideWith(SetupAction.new),
          ],
        );
        addTearDown(scoped.dispose);
        globalState.container = scoped;
        final setup = scoped.read(setupActionProvider.notifier);
        final rendered = await setup.getProfile(
          setupState: nullProfileSetupState.copyWith(profileId: profile.id),
          patchConfig: scoped.read(patchClashConfigProvider),
        );
        final generationDir = Directory(
          '${tempDir.path}${Platform.pathSeparator}prepared-${profile.id}',
        );
        await generationDir.create(recursive: true);
        final generationConfig = File(
          '${generationDir.path}${Platform.pathSeparator}config.yaml',
        );
        await generationConfig.writeAsString(rendered.yaml, flush: true);
        String? requestedFingerprint;
        when(
          () => core.getPreparedRuleGeneration(
            profileId: profile.id,
            fingerprint: any(named: 'fingerprint'),
          ),
        ).thenAnswer((invocation) async {
          requestedFingerprint =
              invocation.namedArguments[#fingerprint]! as String;
          return {
            'generation': 'verified-generation',
            'config-path': generationConfig.path,
          };
        });
        when(
          () => core.activateRuleGeneration(
            profileId: profile.id,
            generation: 'verified-generation',
          ),
        ).thenAnswer((_) async => {'config-path': generationConfig.path});

        final stopwatch = Stopwatch()..start();
        expect(await setup.fullSetup(profileSwitched: true), isTrue);
        while (scoped.read(groupsProvider).isEmpty &&
            stopwatch.elapsed < const Duration(seconds: 1)) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }

        expect(
          requestedFingerprint,
          sha256.convert(rendered.yaml.codeUnits).toString(),
        );
        verify(
          () => core.activateRuleGeneration(
            profileId: profile.id,
            generation: 'verified-generation',
          ),
        ).called(1);
        verify(() => core.setupConfig(any())).called(1);
        verifyNever(
          () => core.prewarmProxyProvider(
            name: any(named: 'name'),
            definition: any(named: 'definition'),
            targetPath: any(named: 'targetPath'),
            timeoutMilliseconds: any(named: 'timeoutMilliseconds'),
          ),
        );
        verifyNever(
          () => core.prewarmRuleProvider(
            name: any(named: 'name'),
            definition: any(named: 'definition'),
            targetPath: any(named: 'targetPath'),
          ),
        );
        expect(scoped.read(groupsProvider).map((group) => group.name), [
          'Proxy',
        ]);
        expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
      },
    );

    test(
      'a profile that fails to build still pushes the empty config to core',
      () async {
        final profile = Profile.normal(label: 'p');
        final core = _MockCoreHandlerInterface();
        when(
          () => core.getProfileConfig(any()),
        ).thenThrow(Exception('broken yaml'));
        String? pushedConfig;
        when(() => core.setupConfig(any())).thenAnswer((_) async {
          pushedConfig = await File(
            await appPath.configFilePath,
          ).readAsString();
          return '';
        });
        final scoped = ProviderContainer(
          overrides: [
            profilesProvider.overrideWith(() => TestProfiles([profile])),
            currentProfileIdProvider.overrideWithBuild((_, _) => profile.id),
            setupStateProvider.overrideWith(
              (_, profileId) =>
                  nullProfileSetupState.copyWith(profileId: profileId),
            ),
            coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
            setupActionProvider.overrideWith(SetupAction.new),
          ],
        );
        addTearDown(scoped.dispose);

        final succeeded = await scoped
            .read(setupActionProvider.notifier)
            .applyProfile(force: true);

        expect(succeeded, isFalse);
        expect(pushedConfig, isEmpty);
        expect(scoped.read(currentProfileIdProvider), profile.id);
      },
    );

    test(
      'a config write failure reports setup as failed without calling core',
      () async {
        final configPath = await appPath.configFilePath;
        final configFile = File(configPath);
        if (await configFile.exists()) {
          await configFile.delete();
        }
        final configAsDirectory = Directory(configPath);
        await configAsDirectory.create(recursive: true);

        final core = _MockCoreHandlerInterface();
        when(() => core.setupConfig(any())).thenAnswer((_) async => '');
        final scoped = ProviderContainer(
          overrides: [
            currentProfileProvider.overrideWithValue(null),
            setupStateProvider.overrideWith((_, _) => nullProfileSetupState),
            coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
            setupActionProvider.overrideWith(SetupAction.new),
          ],
        );
        addTearDown(scoped.dispose);

        try {
          final succeeded = await scoped
              .read(setupActionProvider.notifier)
              .applyProfile(force: true);

          expect(succeeded, isFalse);
          verifyNever(() => core.setupConfig(any()));
        } finally {
          await configAsDirectory.delete(recursive: true);
        }
      },
    );

    test(
      'a rejected setupConfig without a handoff reports failure, not success',
      () async {
        final core = _MockCoreHandlerInterface();
        when(() => core.setupConfig(any())).thenThrow(StateError('rejected'));
        final scoped = ProviderContainer(
          overrides: [
            currentProfileProvider.overrideWithValue(null),
            setupStateProvider.overrideWith((_, _) => nullProfileSetupState),
            coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
            setupActionProvider.overrideWith(SetupAction.new),
          ],
        );
        addTearDown(scoped.dispose);

        final succeeded = await scoped
            .read(setupActionProvider.notifier)
            .applyProfile(force: true);

        expect(succeeded, isFalse);
        verify(() => core.setupConfig(any())).called(1);
      },
    );

    test(
      'a listener handoff failure during initialize rolls back running',
      () async {
        final core = _MockCoreHandlerInterface();
        when(() => core.setupConfig(any())).thenAnswer((_) async => '');
        final scoped = ProviderContainer(
          overrides: [
            currentProfileProvider.overrideWithValue(null),
            setupStateProvider.overrideWith((_, _) => nullProfileSetupState),
            coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
            setupActionProvider.overrideWith(
              _ListenerHandoffFailureSetupAction.new,
            ),
          ],
        );
        addTearDown(scoped.dispose);
        final handoffAction =
            scoped.read(setupActionProvider.notifier)
                as _ListenerHandoffFailureSetupAction;

        await handoffAction.setRunning(true, initialize: true);

        expect(handoffAction.coreRunningCalls, [true, false]);
        expect(scoped.read(runTimeProvider), isNull);
        verify(() => core.setupConfig(any())).called(1);
      },
    );

    test(
      'a non-empty setupConfig message during initialize rolls back running',
      () async {
        final core = _MockCoreHandlerInterface();
        when(
          () => core.setupConfig(any()),
        ).thenAnswer((_) async => 'config rejected');
        final scoped = ProviderContainer(
          overrides: [
            currentProfileProvider.overrideWithValue(null),
            setupStateProvider.overrideWith((_, _) => nullProfileSetupState),
            coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
            setupActionProvider.overrideWith(_MessageFailureSetupAction.new),
          ],
        );
        addTearDown(scoped.dispose);
        final messageAction =
            scoped.read(setupActionProvider.notifier)
                as _MessageFailureSetupAction;

        await messageAction.setRunning(true, initialize: true);

        expect(messageAction.coreRunningCalls, [true, false]);
        expect(scoped.read(runTimeProvider), isNull);
        verify(() => core.setupConfig(any())).called(1);
      },
    );
  });
}
