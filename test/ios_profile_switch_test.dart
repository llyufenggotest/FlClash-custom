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
      final start = manager.indexOf('ref.listenManual(currentProfileIdProvider');
      expect(start, greaterThan(-1),
          reason: 'the profile-id listener must still exist');
      final body = manager.substring(
        start,
        manager.indexOf('ref.listenManual(updateParamsProvider', start),
      );

      expect(body, contains('fullSetup(profileSwitched: prev != null)'),
          reason:
              'a real switch has a previous profile; the first selection at '
              'startup must not tear anything down');
    });

    test('fullSetup forwards the switch flag into the setup run', () {
      final setup = source('lib/providers/actions/setup.dart');
      final start = setup.indexOf('void fullSetup(');
      expect(start, greaterThan(-1));
      final body = setup.substring(start, setup.indexOf('\n  }', start));

      expect(body, contains('bool profileSwitched = false'));
      expect(body, contains('_runSetup(force: true, profileSwitched: profileSwitched)'));
    });

    test('the release happens before the new profile is applied', () {
      final setup = source('lib/providers/actions/setup.dart');
      final signatureAt = setup.indexOf('Future<void> _runSetup(');
      expect(signatureAt, greaterThan(-1));
      // The parameter list is multi-line, so the body starts after `async {`:
      // slicing from the signature would stop at the closing `}) async {`.
      final start = setup.indexOf('async {', signatureAt);
      final body = setup.substring(start, setup.indexOf('\n  }', start));

      final releaseAt = body.indexOf('_releasePreviousProfile()');
      final schedulerAt = body.indexOf('_setupScheduler.run(');
      expect(releaseAt, greaterThan(-1),
          reason: 'a switch must release the previous profile');
      expect(schedulerAt, greaterThan(-1));
      expect(releaseAt, lessThan(schedulerAt),
          reason:
              'releasing after the new config was pushed would hold both '
              'profiles in memory at the same time -- the peak that has to go');
      expect(body, contains('if (profileSwitched)'),
          reason: 'a plain reload must not drop the user\'s connections');
    });

    test('releasing closes the live connections and never blocks the switch',
        () {
      final setup = source('lib/providers/actions/setup.dart');
      final start = setup.indexOf('Future<void> _releasePreviousProfile()');
      expect(start, greaterThan(-1));
      final body = setup.substring(start, setup.indexOf('\n  }', start));

      expect(body, contains('coreController.closeConnections()'),
          reason: 'trackers and sockets of the old profile must be dropped');
      expect(body, contains('try {'));
      expect(body, contains('catch (error)'),
          reason:
              'a core that is not up yet has nothing to release; that must not '
              'abort the switch');
      expect(body, contains('coreFailureLogLevel(error)'),
          reason: 'an expected failure must not be logged as a warning');
    });

    test('a switch is never treated as a redundant reload', () {
      final setup = source('lib/providers/actions/setup.dart');
      final start = setup.indexOf('final skipRedundantReload =');
      expect(start, greaterThan(-1));
      final body = setup.substring(start, setup.indexOf(';', start));

      expect(body, contains('!profileSwitched'),
          reason:
              'two profiles can render identical YAML; the core still has to '
              'rebuild so the stale providers are closed');
    });

    test('the switch flag is threaded through to _setupConfig', () {
      final setup = source('lib/providers/actions/setup.dart');
      final start = setup.indexOf('Future<_SetupTaskResult> _setupConfig(');
      expect(start, greaterThan(-1));
      final signature = setup.substring(start, setup.indexOf('}) async {', start));

      expect(signature, contains('bool profileSwitched = false'));
    });
  });
}
