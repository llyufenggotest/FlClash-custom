import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-level contract for the redundant-config-reload fix.
///
/// The 2026-08-29 device trace showed the iOS Network Extension reloading the
/// full configuration five times in four minutes. Each reload re-read geodata,
/// rebuilt the 111826-record GeoSite matcher and re-fetched every remote
/// rule-provider; while that ran the extension stopped answering provider
/// messages, producing 51 `network_extension_timeout` failures and 45 empty
/// responses (the empty proxies page).
///
/// The trigger was Runner sending `start` on every `invalid -> connected`
/// transition — i.e. every foreground return — and `_setupConfig` honouring the
/// forced apply because its "already applied" fingerprint lived only in memory
/// and was therefore always null after a relaunch.
void main() {
  String source(String path) => File(path).readAsStringSync();

  group('applied-config fingerprint is durable', () {
    test('preferences expose a persisted applied-config md5', () {
      final prefs = source('lib/common/preferences.dart');
      expect(prefs, contains('getAppliedConfigMd5'));
      expect(prefs, contains('setAppliedConfigMd5'));
      expect(prefs, contains('appliedConfigMd5Key'));
    });

    test('the storage key is a real constant, not an inline literal', () {
      final constant = source('lib/common/constant.dart');
      expect(constant, contains("const appliedConfigMd5Key = 'applied_config_md5'"));
    });

    test('setup falls back to the persisted md5 when memory has none', () {
      final setup = source('lib/providers/actions/setup.dart');
      expect(
        setup,
        contains('globalState.lastConfigMd5 ??\n        await preferences.getAppliedConfigMd5()'),
      );
    });

    test('a successful push records the fingerprint durably', () {
      final setup = source('lib/providers/actions/setup.dart');
      expect(setup, contains('await preferences.setAppliedConfigMd5(yamlMd5)'));
    });
  });

  group('redundant reloads are skipped, real ones are not', () {
    test('iOS skips a forced apply only while the tunnel is running', () {
      final setup = source('lib/providers/actions/setup.dart');
      expect(
        setup,
        contains('matchesAppliedConfig && (!force || (system.isIOS && _isRunning))'),
      );
    });

    test('the skip is gated on the on-disk config actually matching', () {
      final setup = source('lib/providers/actions/setup.dart');
      expect(setup, contains('final diskMatches = await configFile.exists()'));
      expect(setup, contains(".readAsString()).toMd5() == yamlMd5"));
    });

    test('skipping the push still runs the core-start side effect', () {
      final setup = source('lib/providers/actions/setup.dart');
      final skipStart = setup.indexOf('if (skipRedundantReload) {');
      expect(skipStart, greaterThan(-1));
      final skipBody = setup.substring(skipStart, skipStart + 700);
      expect(skipBody, contains('await preloadInvoke?.call()'));
      expect(skipBody, contains('return _SetupTaskResult.completed'));
    });

    test('stopping the tunnel forgets the fingerprint on iOS', () {
      final setup = source('lib/providers/actions/setup.dart');
      final stopStart = setup.indexOf('Future<void> _stop(_RunRequest request)');
      final stopEnd = setup.indexOf('Future<void> _setCoreRunning');
      expect(stopStart, greaterThan(-1));
      expect(stopEnd, greaterThan(stopStart));
      final stopBody = setup.substring(stopStart, stopEnd);
      expect(stopBody, contains('await preferences.setAppliedConfigMd5(null)'));
      expect(stopBody, contains('globalState.lastConfigMd5 = null'));
    });

    test('non-iOS platforms keep honouring a forced apply', () {
      final setup = source('lib/providers/actions/setup.dart');
      // The force escape hatch must remain conditional on system.isIOS so
      // Android and desktop, where the core is a fresh in-process instance,
      // still reapply on demand.
      expect(setup, isNot(contains('matchesAppliedConfig && _isRunning')));
      expect(setup, contains('system.isIOS && _isRunning'));
    });
  });
}
