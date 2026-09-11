import 'dart:async';

import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/desktop/model.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/core/rule_generation_preparer.dart';
import 'package:fl_clash/core/rule_preparation_scheduler.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

class MockCoreHandlerInterface extends Mock implements CoreHandlerInterface {}

void main() {
  late MockCoreHandlerInterface mock;
  late CoreController controller;

  setUpAll(() {
    registerFallbackValue(
      const SetupParams(selectedMap: {}, testUrl: 'http://x.com'),
    );
    registerFallbackValue(const InitParams(homeDir: '.', version: 1));
    registerFallbackValue(
      const UpdateParams(
        tun: Tun(),
        mixedPort: 7890,
        allowLan: true,
        findProcessMode: FindProcessMode.off,
        mode: Mode.rule,
        logLevel: LogLevel.info,
        ipv6: false,
        tcpConcurrent: false,
        externalController: '',
        secret: '',
        unifiedDelay: false,
      ),
    );
    registerFallbackValue(
      const ChangeProxyParams(groupName: 'G', proxyName: 'P'),
    );
    registerFallbackValue(
      const UpdateGeoDataParams(geoType: 't', geoName: 'n'),
    );
    registerFallbackValue(const GetOverlayNetworkStatusParams(targets: []));
    registerFallbackValue(OverlayNetworkKind.tailscale);
  });

  setUp(() {
    mock = MockCoreHandlerInterface();
    CoreController.resetInstance();
    rulePreparationScheduler.reset();
    preparedGenerationScheduler.reset();
    controller = CoreController.test(mock);
  });

  tearDown(() {
    CoreController.resetInstance();
  });

  group('CoreController singleton', () {
    test('test constructor injects mock interface', () {
      expect(controller, isA<CoreController>());
    });

    test('resetInstance allows fresh construction', () {
      CoreController.resetInstance();
      final instance = CoreController.test(mock);
      expect(instance, isA<CoreController>());
    });
  });

  group('lifecycle methods', () {
    test('start, restart, stop, and close delegate to interface', () async {
      const result = CoreLifecycleResult(
        revision: 1,
        outcome: CoreLifecycleOutcome.applied,
      );
      when(() => mock.start()).thenAnswer((_) async => result);
      when(() => mock.restart()).thenAnswer((_) async => result);
      when(() => mock.stop()).thenAnswer((_) async => result);
      when(() => mock.close()).thenAnswer((_) async => result);

      expect(await controller.start(), same(result));
      expect(await controller.restart(), same(result));
      expect(await controller.stop(), same(result));
      expect(await controller.close(), same(result));

      verify(() => mock.start()).called(1);
      verify(() => mock.restart()).called(1);
      verify(() => mock.stop()).called(1);
      verify(() => mock.close()).called(1);
    });

    test('isInit delegates to interface', () async {
      when(() => mock.isInit).thenAnswer((_) async => true);
      final result = await controller.isInit;
      expect(result, true);
    });

    test('crash delegates to interface', () async {
      when(() => mock.crash()).thenAnswer((_) async => true);

      await controller.crash();

      verify(() => mock.crash()).called(1);
    });
  });

  group('config methods', () {
    test('validateConfig delegates to interface', () async {
      when(() => mock.validateConfig('/path')).thenAnswer((_) async => 'ok');
      final result = await controller.validateConfig('/path');
      expect(result, 'ok');
      verify(() => mock.validateConfig('/path')).called(1);
    });

    test('updateConfig delegates to interface', () async {
      const params = UpdateParams(
        tun: Tun(enable: false),
        mixedPort: 7890,
        allowLan: true,
        findProcessMode: FindProcessMode.off,
        mode: Mode.rule,
        logLevel: LogLevel.info,
        ipv6: false,
        tcpConcurrent: false,
        externalController: '',
        secret: '',
        unifiedDelay: false,
      );
      when(() => mock.updateConfig(params)).thenAnswer((_) async => 'ok');
      final result = await controller.updateConfig(params);
      expect(result, 'ok');
    });

    test('isolated preparation admits its published candidate path', () async {
      const params = SetupParams(selectedMap: {}, testUrl: 'http://x.com');
      const candidatePath = '/app-group/prewarm/7/generations/id/config.yaml';
      final events = <String>[];
      when(() => mock.validateCandidateConfigAtPath(candidatePath)).thenAnswer((
        _,
      ) async {
        events.add('admit');
        return '';
      });

      final result = await controller.setupConfig(
        params: params,
        preparationConfig: 'rules: []',
        preparationProfileId: 7,
        prepareBeforePreload: true,
        prepareRuleGenerationOverride:
            ({required String config, required int profileId}) async {
              events.add('prepare');
              return const RuleGenerationPreparation(
                fingerprint: 'fingerprint',
                config: 'mode: direct',
                generation: 'generation',
                configPath: candidatePath,
              );
            },
        persistPreparedConfig: (_) async => events.add('stage'),
        preloadInvoke: () async => events.add('preload'),
      );

      expect(result, '');
      expect(events, ['prepare', 'stage', 'admit', 'preload']);
      verify(() => mock.validateCandidateConfigAtPath(candidatePath)).called(1);
      verifyNever(() => mock.setupConfig(params));
    });

    test(
      'isolated preparation preserves the original error when no path exists',
      () async {
        const params = SetupParams(selectedMap: {}, testUrl: 'http://x.com');
        var preloadStarted = false;

        final result = await controller.setupConfig(
          params: params,
          preparationConfig: 'rules: []',
          preparationProfileId: 7,
          prepareBeforePreload: true,
          prepareRuleGenerationOverride:
              ({required String config, required int profileId}) async {
                throw StateError('publish failed: App Group home mismatch');
              },
          preloadInvoke: () async => preloadStarted = true,
        );

        expect(result, contains('publish failed: App Group home mismatch'));
        expect(result, isNot(contains('prepared config path is missing')));
        expect(preloadStarted, isFalse);
      },
    );

    test('coalesced waiter receives the prepared candidate directly', () async {
      const params = SetupParams(selectedMap: {}, testUrl: 'http://x.com');
      const candidatePath = '/app-group/prewarm/7/generations/id/config.yaml';
      final gate = Completer<void>();
      var prepareInvocations = 0;
      when(
        () => mock.validateCandidateConfigAtPath(candidatePath),
      ).thenAnswer((_) async => '');

      Future<RuleGenerationPreparation> prepare({
        required String config,
        required int profileId,
      }) async {
        prepareInvocations++;
        await gate.future;
        return const RuleGenerationPreparation(
          fingerprint: 'fingerprint',
          config: 'mode: direct',
          generation: 'generation',
          configPath: candidatePath,
        );
      }

      final persisted = <String>[];
      final first = controller.setupConfig(
        params: params,
        preparationConfig: 'rules: []',
        preparationProfileId: 7,
        prepareBeforePreload: true,
        prepareRuleGenerationOverride: prepare,
        persistPreparedConfig: (config) async => persisted.add('first:$config'),
      );
      final second = controller.setupConfig(
        params: params,
        preparationConfig: 'rules: []',
        preparationProfileId: 7,
        prepareBeforePreload: true,
        prepareRuleGenerationOverride: prepare,
        persistPreparedConfig: (config) async =>
            persisted.add('second:$config'),
        preloadInvoke: () async {},
      );
      await Future<void>.delayed(Duration.zero);
      expect(prepareInvocations, 1);
      gate.complete();

      expect(await first, '');
      expect(await second, '');
      expect(
        persisted,
        containsAll(['first:mode: direct', 'second:mode: direct']),
      );
      verify(() => mock.validateCandidateConfigAtPath(candidatePath)).called(1);
    });

    test('connect reuses an in-flight subscription prewarm', () async {
      const params = SetupParams(selectedMap: {}, testUrl: 'http://x.com');
      final setupCompleter = Completer<String>();
      var setupInvocations = 0;
      var preloadInvocations = 0;
      when(() => mock.setupConfig(params)).thenAnswer((_) {
        setupInvocations++;
        return setupCompleter.future;
      });

      final prewarm = controller.setupConfig(
        params: params,
        prepareBeforePreload: true,
      );
      final connect = controller.setupConfig(
        params: params,
        prepareBeforePreload: true,
        preloadInvoke: () async => preloadInvocations++,
      );
      await Future<void>.delayed(Duration.zero);

      expect(setupInvocations, 2);
      expect(preloadInvocations, 0);
      setupCompleter.complete('');
      expect(await prewarm, '');
      expect(await connect, '');
      expect(preloadInvocations, 1);
    });

    test('ready subscription prewarm lets connect skip Runner setup', () async {
      const params = SetupParams(selectedMap: {}, testUrl: 'http://x.com');
      var setupInvocations = 0;
      var preloadInvocations = 0;
      when(() => mock.setupConfig(params)).thenAnswer((_) async {
        setupInvocations++;
        return '';
      });

      expect(
        await controller.setupConfig(
          params: params,
          prepareBeforePreload: true,
        ),
        '',
      );
      expect(
        await controller.setupConfig(
          params: params,
          prepareBeforePreload: true,
          preloadInvoke: () async => preloadInvocations++,
        ),
        '',
      );

      expect(setupInvocations, 2);
      expect(preloadInvocations, 1);
    });

    test('failed prewarm preserves a ready older fingerprint', () async {
      const params = SetupParams(selectedMap: {}, testUrl: 'http://x.com');
      final results = ['', 'download failed', ''];
      var setupInvocations = 0;
      when(() => mock.setupConfig(params)).thenAnswer((_) async {
        return results[setupInvocations++];
      });

      expect(
        await controller.setupConfig(
          params: params,
          prepareBeforePreload: true,
        ),
        '',
      );
      expect(
        await controller.setupConfig(
          params: params,
          prepareBeforePreload: true,
        ),
        'download failed',
      );
      expect(
        await controller.setupConfig(
          params: params,
          prepareBeforePreload: true,
        ),
        '',
      );

      expect(setupInvocations, 3);
    });

    test('prewarm without a start callback still has a bounded wait', () async {
      const params = SetupParams(selectedMap: {}, testUrl: 'http://x.com');
      final setupCompleter = Completer<String>();
      when(
        () => mock.setupConfig(params),
      ).thenAnswer((_) => setupCompleter.future);

      final result = await controller.setupConfig(
        params: params,
        prepareBeforePreload: true,
        rulePreparationTimeout: const Duration(milliseconds: 10),
      );

      expect(result, contains('rule preparation timed out'));
      setupCompleter.complete('');
    });

    test(
      'same YAML with different setup params is prepared separately',
      () async {
        const first = SetupParams(
          selectedMap: {'group': 'a'},
          testUrl: 'http://a.com',
        );
        const second = SetupParams(
          selectedMap: {'group': 'b'},
          testUrl: 'http://b.com',
        );
        when(() => mock.setupConfig(any())).thenAnswer((_) async => '');

        await controller.setupConfig(params: first, prepareBeforePreload: true);
        await controller.setupConfig(
          params: second,
          prepareBeforePreload: true,
        );

        verify(() => mock.setupConfig(first)).called(1);
        verify(() => mock.setupConfig(second)).called(1);
      },
    );

    test(
      'iOS setup prepares rule artifacts before starting the extension',
      () async {
        const params = SetupParams(selectedMap: {}, testUrl: 'http://x.com');
        final setupCompleter = Completer<String>();
        final events = <String>[];
        when(() => mock.setupConfig(params)).thenAnswer((_) {
          events.add('setup');
          return setupCompleter.future;
        });

        final setupFuture = controller.setupConfig(
          params: params,
          prepareBeforePreload: true,
          preloadInvoke: () async => events.add('preload'),
        );
        await Future<void>.delayed(Duration.zero);
        expect(events, ['setup']);

        setupCompleter.complete('');
        expect(await setupFuture, '');
        expect(events, ['setup', 'preload']);
      },
    );

    test('iOS setup failure does not start an unprepared extension', () async {
      const params = SetupParams(selectedMap: {}, testUrl: 'http://x.com');
      final events = <String>[];
      when(() => mock.setupConfig(params)).thenAnswer((_) async {
        events.add('setup');
        return 'rule provider preflight failed';
      });

      final result = await controller.setupConfig(
        params: params,
        prepareBeforePreload: true,
        preloadInvoke: () async => events.add('preload'),
      );
      expect(result, 'rule provider preflight failed');
      expect(events, ['setup']);
    });

    test('iOS setup timeout does not start an unprepared extension', () async {
      const params = SetupParams(selectedMap: {}, testUrl: 'http://x.com');
      final events = <String>[];
      final setupCompleter = Completer<String>();
      when(() => mock.setupConfig(params)).thenAnswer((_) {
        events.add('setup');
        return setupCompleter.future;
      });

      final result = await controller.setupConfig(
        params: params,
        prepareBeforePreload: true,
        rulePreparationTimeout: const Duration(milliseconds: 10),
        preloadInvoke: () async => events.add('preload'),
      );

      expect(result, contains('rule preparation timed out'));
      expect(result, contains('10ms'));
      expect(events, ['setup']);

      setupCompleter.complete('');
      await Future<void>.delayed(Duration.zero);
      expect(events, ['setup']);
    });

    test(
      'iOS setup exception is preserved and does not start the extension',
      () async {
        const params = SetupParams(selectedMap: {}, testUrl: 'http://x.com');
        final providerError = StateError('BanAD provider file is missing');
        var preloadStarted = false;
        when(
          () => mock.setupConfig(params),
        ).thenAnswer((_) => Future<String>.error(providerError));

        await expectLater(
          controller.setupConfig(
            params: params,
            prepareBeforePreload: true,
            preloadInvoke: () async => preloadStarted = true,
          ),
          throwsA(same(providerError)),
        );
        expect(preloadStarted, isFalse);
      },
    );

    test('non-iOS setup keeps setup and preload parallel', () async {
      const params = SetupParams(selectedMap: {}, testUrl: 'http://x.com');
      final preloadCompleter = Completer<void>();
      final events = <String>[];
      when(() => mock.setupConfig(params)).thenAnswer((_) {
        events.add('setup');
        return Future.value('ok');
      });

      final setupFuture = controller.setupConfig(
        params: params,
        prepareBeforePreload: false,
        preloadInvoke: () async {
          events.add('preload');
          await preloadCompleter.future;
        },
      );
      var completed = false;
      unawaited(setupFuture.then((_) => completed = true));
      await Future<void>.delayed(Duration.zero);

      expect(events, ['setup', 'preload']);
      expect(completed, isFalse);

      preloadCompleter.complete();
      expect(await setupFuture, 'ok');
    });
  });

  group('proxy methods', () {
    test('changeProxy delegates to interface', () async {
      const params = ChangeProxyParams(groupName: 'G1', proxyName: 'P1');
      when(
        () => mock.changeProxy(params, closeConnections: true),
      ).thenAnswer((_) async => 'ok');
      final result = await controller.changeProxy(
        params,
        closeConnections: true,
      );
      expect(result, 'ok');
      verify(() => mock.changeProxy(params, closeConnections: true)).called(1);
    });
  });

  group('connection methods', () {
    test('getConnections delegates structured connections', () async {
      final connection = TrackerInfo.fromJson({
        'id': '1',
        'metadata': {'network': 'tcp'},
        'upload': 0,
        'download': 0,
        'start': '2024-01-01',
        'chains': ['Proxy'],
        'rule': 'DIRECT',
        'rulePayload': '',
      });
      when(() => mock.getConnections()).thenAnswer((_) async => [connection]);
      final result = await controller.getConnections();
      expect(result.length, 1);
      expect(result.first.id, '1');
    });

    test('getConnections handles empty connections', () async {
      when(() => mock.getConnections()).thenAnswer((_) async => []);
      final result = await controller.getConnections();
      expect(result, isEmpty);
    });

    test('closeConnection delegates', () async {
      when(() => mock.closeConnection('id1')).thenAnswer((_) async => true);
      await controller.closeConnection('id1');
      verify(() => mock.closeConnection('id1')).called(1);
    });
  });

  group('external providers', () {
    test('getExternalProviders delegates structured providers', () async {
      final provider = ExternalProvider(
        name: 'provider1',
        type: 'Proxy',
        count: 5,
        vehicleType: 'HTTP',
        updateAt: DateTime.now(),
      );
      when(
        () => mock.getExternalProviders(),
      ).thenAnswer((_) async => [provider]);
      final result = await controller.getExternalProviders();
      expect(result.length, 1);
      expect(result.first.name, 'provider1');
    });

    test('getExternalProviders handles empty list', () async {
      when(() => mock.getExternalProviders()).thenAnswer((_) async => []);
      final result = await controller.getExternalProviders();
      expect(result, isEmpty);
    });

    test('getExternalProvider returns null when missing', () async {
      when(() => mock.getExternalProvider(any())).thenAnswer((_) async => null);
      final result = await controller.getExternalProvider('test');
      expect(result, isNull);
    });

    test('getOverlayNetworkStatus delegates structured batch', () async {
      const status = OverlayNetworkStatus(
        name: 'tailnet',
        kind: OverlayNetworkKind.tailscale,
        state: OverlayNetworkState.connected,
        rawState: 'Running',
        networkName: 'example.com',
        authUrl: '',
        error: '',
      );
      when(
        () => mock.getOverlayNetworkStatus(any()),
      ).thenAnswer((_) async => [status]);
      const params = GetOverlayNetworkStatusParams(
        targets: [
          OverlayNetworkTarget(
            name: 'tailnet',
            kind: OverlayNetworkKind.tailscale,
            level: OverlayNetworkDetailLevel.summary,
          ),
        ],
      );

      expect(await controller.getOverlayNetworkStatus(params), [status]);
      verify(() => mock.getOverlayNetworkStatus(params)).called(1);
    });

    test('activateOverlayNetwork delegates target identity', () async {
      const status = OverlayNetworkStatus(
        name: 'tailnet',
        kind: OverlayNetworkKind.tailscale,
        state: OverlayNetworkState.connected,
        rawState: 'Running',
        networkName: 'example.com',
        authUrl: '',
        error: '',
      );
      when(
        () => mock.activateOverlayNetwork(any(), any()),
      ).thenAnswer((_) async => status);

      expect(
        await controller.activateOverlayNetwork(
          'tailnet',
          OverlayNetworkKind.tailscale,
        ),
        status,
      );
      verify(
        () => mock.activateOverlayNetwork(
          'tailnet',
          OverlayNetworkKind.tailscale,
        ),
      ).called(1);
    });

    test('pingTailscaleNode delegates target and address', () async {
      when(
        () => mock.pingTailscaleNode(any(), any()),
      ).thenAnswer((_) async => const TailscalePingResult(latencyMs: 23));

      final result = await controller.pingTailscaleNode(
        'tailnet',
        '100.64.0.1',
      );

      expect(result.latencyMs, 23);
      verify(() => mock.pingTailscaleNode('tailnet', '100.64.0.1')).called(1);
    });

    test('logoutTailscale delegates target name', () async {
      when(() => mock.logoutTailscale(any())).thenAnswer((_) async => true);

      expect(await controller.logoutTailscale('tailnet'), isTrue);
      verify(() => mock.logoutTailscale('tailnet')).called(1);
    });
  });

  group('traffic methods', () {
    test('getTraffic delegates structured traffic', () async {
      when(
        () => mock.getTraffic(false),
      ).thenAnswer((_) async => const Traffic(up: 1, down: 2));
      final result = await controller.getTraffic(false);
      expect(result.up, 1);
      expect(result.down, 2);
    });

    test('getTotalTraffic delegates structured traffic', () async {
      when(
        () => mock.getTotalTraffic(false),
      ).thenAnswer((_) async => const Traffic(up: 3, down: 4));
      final result = await controller.getTotalTraffic(false);
      expect(result.up, 3);
      expect(result.down, 4);
    });

    test('getMemory delegates numeric memory', () async {
      when(() => mock.getMemory()).thenAnswer((_) async => 2048);
      final result = await controller.getMemory();
      expect(result, 2048);
    });

    test('getGoroutineCount delegates numeric count', () async {
      when(() => mock.getGoroutineCount()).thenAnswer((_) async => 42);
      final result = await controller.getGoroutineCount();
      expect(result, 42);
    });
  });

  group('misc methods', () {
    test('getDelay delegates structured delay', () async {
      when(() => mock.asyncTestDelay(any(), any())).thenAnswer(
        (_) async => const Delay(name: 'P1', value: 100, url: 'test.com'),
      );
      final result = await controller.getDelay('test.com', 'P1');
      expect(result?.name, 'P1');
      expect(result?.value, 100);
    });

    test('startListener delegates', () async {
      when(() => mock.startListener()).thenAnswer((_) async => true);
      final result = await controller.startListener();
      expect(result, true);
    });

    test('stopListener delegates', () async {
      when(() => mock.stopListener()).thenAnswer((_) async => false);
      final result = await controller.stopListener();
      expect(result, false);
    });

    test('updateGeoData delegates', () async {
      when(() => mock.updateGeoData('MMDB')).thenAnswer((_) async => 'ok');
      final result = await controller.updateGeoData('MMDB');
      expect(result, 'ok');
    });

    test('requestGc delegates to forceGc', () async {
      when(() => mock.forceGc()).thenAnswer((_) async => true);
      await controller.requestGc();
      verify(() => mock.forceGc()).called(1);
    });

    test('clearEffect delegates', () async {
      when(() => mock.clearEffect(42)).thenAnswer((_) async => 'ok');
      final result = await controller.clearEffect(42);
      expect(result, 'ok');
    });
  });
}
