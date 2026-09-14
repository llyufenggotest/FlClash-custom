import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/theme.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/manager/core_manager.dart';
import 'package:fl_clash/manager/status_manager.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/action.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/views/navigation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../helpers/test_profiles.dart';

class _MockCoreHandlerInterface extends Mock implements CoreHandlerInterface {}

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);

  final String root;

  @override
  Future<String?> getTemporaryPath() async => root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => root;
}

const _setupState = SetupState(
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

const _runtimeProxies = ProxiesData(
  all: ['Proxy', 'Node'],
  proxies: {
    'Proxy': {
      'name': 'Proxy',
      'type': 'Selector',
      'now': 'Node',
      'all': ['Node'],
    },
    'Node': {'name': 'Node', 'type': 'ss'},
  },
);

Future<void> _waitFor(WidgetTester tester, bool Function() condition) async {
  await tester.runAsync(() async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!condition() && DateTime.now().isBefore(deadline)) {
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  });
  expect(condition(), isTrue, reason: 'runtime setup did not settle');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late HttpServer server;
  late StreamSubscription<HttpRequest> serverSubscription;
  late HttpOverrides? previousHttpOverrides;
  late int subscriptionRequests;

  setUpAll(() async {
    registerFallbackValue(const SetupParams(selectedMap: {}, testUrl: ''));
    await AppLocalizations.load(const Locale('en'));
    globalState.packageInfo = PackageInfo(
      appName: 'FlClash',
      packageName: 'com.follow.clash',
      version: '0.0.0',
      buildNumber: '0',
    );
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'profile_url_activation_test_',
    );
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    navigationPort = navigation;
    previousHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    subscriptionRequests = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    serverSubscription = server.listen((request) async {
      if (request.uri.path == '/profile.yaml') {
        subscriptionRequests++;
        request.response.headers.contentType = ContentType.text;
        request.response.write('''
proxies:
  - name: Node
    type: ss
    server: 127.0.0.1
    port: 443
    cipher: aes-128-gcm
    password: test
proxy-groups:
  - name: Proxy
    type: select
    proxies: [Node]
rule-providers:
  ads:
    type: http
    behavior: domain
    url: http://127.0.0.1:${server.port}/rules.yaml
    interval: 86400
rules:
  - MATCH,Proxy
''');
      } else if (request.uri.path == '/rules.yaml') {
        request.response.headers.contentType = ContentType.text;
        request.response.write('payload:\n  - example.com\n');
      } else {
        request.response.statusCode = HttpStatus.notFound;
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    navigationPort = null;
    HttpOverrides.global = previousHttpOverrides;
    await serverSubscription.cancel();
    await server.close(force: true);
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  testWidgets(
    'first URL profile activates without a committed generation and shows proxies',
    (tester) async {
      final core = _MockCoreHandlerInterface();
      when(core.cancelDelayTests).thenAnswer((_) async => true);
      when(
        () => core.setProfileSwitchProbeBarrier(
          token: any(named: 'token'),
          suspended: any(named: 'suspended'),
        ),
      ).thenAnswer((_) async => true);
      when(() => core.validateConfig(any())).thenAnswer((_) async => '');
      when(() => core.getProfileConfig(any())).thenAnswer(
        (_) async => <String, dynamic>{
          'proxies': [
            {
              'name': 'Node',
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
              'proxies': ['Node'],
            },
          ],
          'rule-providers': {
            'ads': {
              'type': 'http',
              'behavior': 'domain',
              'url': 'http://127.0.0.1:${server.port}/rules.yaml',
              'interval': 86400,
            },
          },
          'rule': ['MATCH,Proxy'],
        },
      );
      when(
        () => core.getPreparedRuleGeneration(
          profileId: any(named: 'profileId'),
          fingerprint: any(named: 'fingerprint'),
        ),
      ).thenAnswer((_) async => <String, dynamic>{});
      when(
        () => core.prewarmRuleProvider(
          name: any(named: 'name'),
          definition: any(named: 'definition'),
          targetPath: any(named: 'targetPath'),
        ),
      ).thenThrow(StateError('no committed generation for a new profile'));
      when(() => core.setupConfig(any())).thenAnswer((_) async => '');
      when(() => core.getProxies()).thenAnswer((_) async => _runtimeProxies);
      when(() => core.getExternalProviders()).thenAnswer((_) async => const []);

      final container = ProviderContainer(
        overrides: [
          initProvider.overrideWithBuild((_, _) => true),
          profilesProvider.overrideWith(TestProfiles.new),
          currentProfileIdProvider.overrideWithBuild((_, _) => null),
          setupStateProvider.overrideWith(
            (_, profileId) => _setupState.copyWith(profileId: profileId),
          ),
          coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
        ],
      );
      addTearDown(container.dispose);
      globalState.container = container;

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            navigatorKey: globalState.navigatorKey,
            localizationsDelegates: const [AppLocalizations.delegate],
            supportedLocales: AppLocalizations.delegate.supportedLocales,
            builder: (context, child) {
              globalState.measure = Measure.of(context, 1);
              globalState.theme = CommonTheme.of(context, 1);
              return StatusManager(child: child!);
            },
            home: const CoreManager(child: SizedBox()),
          ),
        ),
      );

      await tester.runAsync(() async {
        await container
            .read(profilesActionProvider.notifier)
            .addProfileFormURL(
              'http://${server.address.address}:${server.port}/profile.yaml',
            );
      });
      await _waitFor(tester, () => container.read(groupsProvider).isNotEmpty);

      expect(subscriptionRequests, 1);
      expect(container.read(currentProfileIdProvider), isNotNull);
      expect(container.read(groupsProvider).map((group) => group.name), [
        'Proxy',
      ]);
      expect(
        container
            .read(navigationItemsStateProvider)
            .value
            .map((item) => item.label),
        contains(PageLabel.proxies),
      );
      verify(() => core.setupConfig(any())).called(1);
      verifyNever(
        () => core.prewarmRuleProvider(
          name: any(named: 'name'),
          definition: any(named: 'definition'),
          targetPath: any(named: 'targetPath'),
        ),
      );

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
