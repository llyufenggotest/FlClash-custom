import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-level contracts for the "single core" subscription switch.
///
/// Tapping another subscription used to leave the previous one's connections
/// draining in the background while the new profile was parsed. The old
/// providers were never closed either (see
/// `core/mihomo/tunnel/provider_close_test.go`), so the previous subscription's
/// health-check goroutines kept probing its nodes forever and pinned them in
/// memory -- the 42-48MB footprint peaks in the 2026-09-01 tester trace.
void main() {
  String source(String relativePath) =>
      File(relativePath).readAsStringSync().replaceAll('\r\n', '\n');

  group('subscription switch releases the previous profile', () {
    test('switching a profile is reported as a switch, startup is not', () {
      final manager = source('lib/manager/core_manager.dart');
      final start = manager.indexOf(
        'ref.listenManual(currentProfileIdProvider',
      );
      expect(
        start,
        greaterThan(-1),
        reason: 'the profile-id listener must still exist',
      );
      final body = manager.substring(
        start,
        manager.indexOf('ref.listenManual(updateParamsProvider', start),
      );

      expect(
        body,
        contains('profileSwitched: prev != null'),
        reason:
            'a real switch has a previous profile; the first selection at '
            'startup must not tear anything down',
      );
    });

    test('fullSetup forwards the switch flag into the setup run', () {
      final setup = source('lib/providers/actions/setup.dart');
      final start = setup.indexOf('Future<bool> fullSetup(');
      expect(start, greaterThan(-1));
      final body = setup.substring(start, setup.indexOf('\n  }', start));

      expect(body, contains('bool profileSwitched = false'));
      expect(body, contains('profileSwitched: profileSwitched'));
    });

    test('preparation does not stop the old tunnel', () {
      final setup = source('lib/providers/actions/setup.dart');
      final signatureAt = setup.indexOf(
        'Future<_SetupTaskResult> _setupConfig(',
      );
      final start = setup.indexOf('async {', signatureAt);
      final end = setup.length;
      expect(signatureAt, greaterThan(-1));
      expect(start, greaterThan(signatureAt));
      final body = setup.substring(start, end);

      expect(body, contains('commitAndActivateIOSConfig('));
      expect(body, isNot(contains('await setCoreRunning(false)')));
    });

    test('running iOS profile switches hot-apply after preparation', () {
      final setup = source('lib/providers/actions/setup.dart');
      final start = setup.indexOf('Future<void> commitAndActivate()');
      final end = setup.indexOf('\n          final message =', start);
      expect(end, greaterThan(start));
      final body = setup.substring(start, end);

      expect(
        body,
        contains('final onlineSwitch = _isRunning && preloadInvoke == null;'),
      );
      expect(body, contains('if (onlineSwitch)'));
      final hotApplyAt = body.indexOf('commitAndHotApplyIOSConfig(');
      final restartAt = body.indexOf('commitAndActivateIOSConfig(');
      expect(hotApplyAt, greaterThan(-1));
      expect(restartAt, greaterThan(hotApplyAt));
      final hotBody = body.substring(hotApplyAt, restartAt);
      expect(hotBody, contains('applyConfig: applyFormalConfig'));
      expect(hotBody, contains('restoreConfig: applyFormalConfig'));
      expect(hotBody, isNot(contains('setCoreRunning(false)')));
      expect(hotBody, isNot(contains('setCoreRunning(true)')));
    });

    test('startup and cold activation keep stale-request arbitration', () {
      final setup = source('lib/providers/actions/setup.dart');
      final start = setup.indexOf('Future<void> commitAndActivate()');
      final end = setup.indexOf('\n          final message =', start);
      expect(end, greaterThan(start));
      final body = setup.substring(start, end);

      expect(body, contains('if (preloadInvoke != null)'));
      expect(body, contains('await preloadInvoke();'));
      expect(body, contains('activationGuard != null && !activationGuard()'));
      expect(body, contains('iOS activation request is no longer current'));
      expect(body, contains('startTunnel: () async'));
      expect(body, contains('return setCoreRunning(true);'));
      expect(
        body.indexOf('activationGuard != null && !activationGuard()'),
        lessThan(body.indexOf('await preloadInvoke();')),
      );
      expect(
        body,
        isNot(contains('final shouldStartTunnel =')),
        reason: 'callback presence must not bypass request/suspend arbitration',
      );
    });

    test('a switch is never treated as a redundant reload', () {
      final setup = source('lib/providers/actions/setup.dart');
      final start = setup.indexOf('final skipRedundantReload =');
      expect(start, greaterThan(-1));
      final body = setup.substring(start, setup.indexOf(';', start));

      expect(
        body,
        contains('!profileSwitched'),
        reason:
            'two profiles can render identical YAML; the core still has to '
            'rebuild so the stale providers are closed',
      );
    });

    test('the switch flag is threaded through to _setupConfig', () {
      final setup = source('lib/providers/actions/setup.dart');
      final start = setup.indexOf('Future<_SetupTaskResult> _setupConfig(');
      expect(start, greaterThan(-1));
      final signature = setup.substring(
        start,
        setup.indexOf('}) async {', start),
      );

      expect(signature, contains('bool profileSwitched = false'));
    });

    test('an online iOS switch hot-applies without restarting the tunnel', () {
      final setup = source('lib/providers/actions/setup.dart');
      final start = setup.indexOf('Future<void> commitAndActivate()');
      final end = setup.indexOf('\n          final message =', start);
      expect(end, greaterThan(start));
      final body = setup.substring(start, end);

      expect(body, contains('if (onlineSwitch)'));
      expect(body, contains('commitAndHotApplyIOSConfig('));
      expect(body, contains('applyConfig: applyFormalConfig'));
      expect(body, contains('restoreConfig: applyFormalConfig'));
      expect(
        body.indexOf('commitAndHotApplyIOSConfig('),
        lessThan(body.indexOf('commitAndActivateIOSConfig(')),
      );
    });

    test('profile switches keep the last proxy page usable while applying', () {
      final setup = source('lib/providers/actions/setup.dart');
      final start = setup.indexOf('Future<bool> fullSetup(');
      final end = setup.indexOf('\n  }', start);
      expect(end, greaterThan(start));
      final body = setup.substring(start, end);

      expect(body, contains('silence: profileSwitched'));
    });
  });
}
