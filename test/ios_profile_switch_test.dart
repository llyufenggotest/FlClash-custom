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
        contains('fullSetup(profileSwitched: prev != null)'),
        reason:
            'a real switch has a previous profile; the first selection at '
            'startup must not tear anything down',
      );
    });

    test('fullSetup forwards the switch flag into the setup run', () {
      final setup = source('lib/providers/actions/setup.dart');
      final start = setup.indexOf('void fullSetup(');
      expect(start, greaterThan(-1));
      final body = setup.substring(start, setup.indexOf('\n  }', start));

      expect(body, contains('bool profileSwitched = false'));
      expect(
        body,
        contains('_runSetup(force: true, profileSwitched: profileSwitched)'),
      );
    });

    test('preparation does not stop the old tunnel', () {
      final setup = source('lib/providers/actions/setup.dart');
      final signatureAt = setup.indexOf('Future<void> _runSetup(');
      final start = setup.indexOf('async {', signatureAt);
      final body = setup.substring(start, setup.indexOf('\n  }', start));

      final schedulerAt = body.indexOf('_setupScheduler.run(');
      final setupAt = body.indexOf('await _setupConfig(');
      expect(schedulerAt, greaterThan(-1));
      expect(setupAt, greaterThan(schedulerAt));
      expect(body, isNot(contains('setCoreRunning(false)')));
    });

    test('every running iOS config change is transactional', () {
      final setup = source('lib/providers/actions/setup.dart');
      final start = setup.indexOf('Future<void> commitAndActivate()');
      final body = setup.substring(start, setup.indexOf('\n        final message =', start));

      expect(
        body,
        contains('final onlineSwitch = _isRunning && preloadInvoke == null;'),
        reason:
            'any formal config replacement while the tunnel is running must '
            'stop, commit, restart, and roll back on failure',
      );
      expect(
        body,
        isNot(contains('profileSwitched && _isRunning')),
        reason: 'ordinary online config edits require the same transaction',
      );
      final activationAt = body.indexOf('commitAndActivateIOSConfig(');
      final commitAt = body.indexOf('persistAtomically: _persistConfigAtomically');
      final stopAt = body.indexOf('stopTunnel: () => setCoreRunning(false)');
      final startAt = body.indexOf('startTunnel: () async');
      expect(activationAt, greaterThan(-1));
      expect(commitAt, greaterThan(activationAt));
      expect(stopAt, greaterThan(commitAt));
      expect(startAt, greaterThan(stopAt));
    });

    test('initialization keeps stale-request and suspend arbitration', () {
      final setup = source('lib/providers/actions/setup.dart');
      final start = setup.indexOf('Future<void> commitAndActivate()');
      final body = setup.substring(start, setup.indexOf('\n        final message =', start));

      expect(body, contains('if (preloadInvoke != null)'));
      expect(body, contains('await preloadInvoke();'));
      expect(body, contains('activationGuard != null && !activationGuard()'));
      expect(body, contains('iOS activation request is no longer current'));
      expect(
        body.indexOf('await preloadInvoke();'),
        lessThan(body.indexOf('return setCoreRunning(true);')),
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
  });
}
