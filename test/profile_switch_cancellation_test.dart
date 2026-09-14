import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String source(String path) =>
      File(path).readAsStringSync().replaceAll('\r\n', '\n');

  group('profile switch cancellation contract', () {
    test('a profile switch cancels stale delay RPC before setup starts', () {
      final manager = source('lib/manager/core_manager.dart');
      final listenerStart = manager.indexOf(
        'ref.listenManual(currentProfileIdProvider',
      );
      final listenerEnd = manager.indexOf('\n    });', listenerStart);
      expect(listenerStart, greaterThan(-1));
      expect(listenerEnd, greaterThan(listenerStart));
      final body = manager.substring(listenerStart, listenerEnd);

      expect(body, contains('cancelDelayTests(cancelCoreRequests: true)'));
      expect(body, contains('beginProfileSwitch()'));
      final setup = source('lib/providers/actions/setup.dart');
      expect(setup, contains('final ownsProfileSelection ='));
      expect(setup, contains('bool activationIsCurrent() =>'));
      expect(setup, contains('activationGuard: activationIsCurrent'));
      expect(
        body.indexOf('cancelDelayTests(cancelCoreRequests: true)'),
        lessThan(body.indexOf('fullSetup(')),
      );
    });

    test(
      'Swift cancellation scope targets delay RPCs without stopping tunnel',
      () {
        final channel = source('ios/Runner/ServiceChannel.swift');
        expect(channel, contains('case "cancelDelayTests"'));
        expect(channel, contains('cancelDelayTestRequests'));
        expect(channel, contains('method: String?'));
        expect(channel, contains('method == "asyncTestDelay"'));
      },
    );

    test('Core exposes cancellation for queued and active probes', () {
      final goConstants = source('core/constant.go');
      final goMethods = source('core/method.go');
      final router = source('ios/Runner/Core/CoreMessageRouter.swift');
      expect(goConstants, contains('cancelDelayTestsMethod'));
      expect(goMethods, contains('cancelDelayTestsMethod: withoutArguments'));
      expect(router, contains('func cancelDelayTests() async'));
      expect(router, contains('CoreRoute.app, CoreRoute.networkExtension'));
      final mailbox = source('ios/NECore/ProviderMessageMailbox.swift');
      expect(mailbox, contains('method == "cancelDelayTests"'));
      expect(mailbox, contains('interruptOutstanding < 1'));
      expect(mailbox, contains('configurationOutstanding < 1'));
    });

    test('profile switch controls bypass normal Runner admission', () {
      final tunnel = source('ios/Runner/Tunnel/TunnelController.swift');
      final router = source('ios/Runner/Core/CoreMessageRouter.swift');
      expect(tunnel, contains('providerMessageLane'));
      expect(tunnel, contains('acquireProviderMessageSlot(lane:'));
      expect(tunnel, contains('case interrupt'));
      expect(tunnel, contains('case configuration'));
      expect(tunnel, contains('method == "setupConfig"'));
      expect(tunnel, contains('method == "updateConfig"'));
      expect(tunnel, contains('mailboxOnlySession'));
      expect(router, contains('setProfileSwitchProbeBarrier'));
      expect(router, contains('control: true'));
      expect(router, contains('Release must converge every route'));
      expect(router, contains('continue'));
    });

    test('profile switch suspends new probes until current setup finishes', () {
      final setup = source('lib/providers/actions/setup.dart');
      final service = source('lib/plugins/service.dart');
      final goConstants = source('core/constant.go');
      final goMethods = source('core/method.go');
      expect(service, contains('setProfileSwitchProbeBarrier'));
      expect(setup, contains('suspended: true'));
      expect(setup, contains('suspended: false'));
      expect(setup, contains('barrierToken'));
      expect(setup, contains('barrierResumed'));
      expect(setup, contains('generation != _profileSwitchGeneration'));
      expect(goConstants, contains('setProfileSwitchProbeBarrierMethod'));
      expect(
        goMethods,
        contains(
          'setProfileSwitchProbeBarrier(params.Token, params.Suspended)',
        ),
      );
      final barrier = source('core/profile_switch_probe_barrier.go');
      expect(
        barrier,
        contains(
          'provider.SuspendHealthCheck(providerHealthChecksSuspended())',
        ),
      );
      expect(barrier, contains('profileSwitchProbeAdmissionCurrent'));
      expect(barrier, contains('cancelDelayTests()'));
      final extensionScheduler = source('core/delay_scheduler_extension.go');
      final defaultScheduler = source('core/delay_scheduler_default.go');
      expect(
        extensionScheduler,
        contains('profileSwitchProbeAdmissionSnapshot()'),
      );
      expect(
        extensionScheduler,
        contains('profileSwitchProbeAdmissionCurrent(epoch)'),
      );
      expect(
        defaultScheduler,
        contains('profileSwitchProbeAdmissionSnapshot()'),
      );
      expect(
        defaultScheduler,
        contains('profileSwitchProbeAdmissionCurrent(epoch)'),
      );
    });

    test('late proxy and provider refreshes are generation guarded', () {
      final proxies = source('lib/providers/actions/proxies.dart');
      final providers = source('lib/providers/app.dart');
      expect(proxies, contains('updateGroups({int? profileId})'));
      expect(proxies, contains('dropping stale profile result'));
      expect(providers, contains('syncProviders({int? profileId})'));
      expect(providers, contains('currentProfileProvider'));
    });
  });
}
