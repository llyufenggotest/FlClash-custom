import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-level contract for the jetsam-kill fix.
///
/// The 2026-08-29 22:46 device traces (two exports) pinned why every tunnel
/// life died. Four consecutive lives logged a final heartbeat of 43, 48, 47 and
/// 47 MB phys_footprint and were killed on the next tick, so the Network
/// Extension's effective ceiling is ~48 MB rather than the assumed 50.
///
/// The climb was driven by delay-test admission mismatch: the app allowed 50
/// concurrent probes while the extension's Go core caps `delayBatchConcurrency`
/// at 8 under `with_low_memory`. The surplus 42 queued *inside* the extension.
/// One trace shows 56 provider messages issued in a single second, 65 in flight
/// at the peak, footprint 32 -> 47 MB in three seconds, then death. Queue
/// pressure also pushed provider-message p50 to 2719 ms against an 8 s budget,
/// producing 51 timeouts (the `network_extension_timeout` dialog) and 45 empty
/// replies (the blank proxies page).
///
/// These are source assertions, not behavioural tests: the Swift side cannot be
/// exercised without a macOS toolchain, and the Dart constant resolves by
/// platform at runtime.
void main() {
  String read(String path) {
    final file = File(path);
    expect(file.existsSync(), isTrue, reason: '$path must exist');
    return file.readAsStringSync();
  }

  group('delay-test concurrency is aligned across the process boundary', () {
    test('the iOS core caps delay probes at 8', () {
      final source = read('core/memory_budget_ios_extension.go');
      expect(
        source,
        contains('const delayBatchConcurrency = 8'),
        reason: 'the Dart and Swift limits mirror this number',
      );
    });

    test('the app sends at most the core concurrency on iOS', () {
      final source = read('lib/common/constant.dart');
      expect(source, contains('const _maxConcurrentDelayTestsIOS = 8'));
      expect(source, contains('const _maxConcurrentDelayTestsDefault = 50'));
      expect(
        source,
        contains('final maxConcurrentDelayTests = system.isIOS'),
        reason: 'must resolve per platform, not stay a single const',
      );
    });

    test('desktop and Android keep the original concurrency', () {
      final source = read('lib/common/constant.dart');
      expect(
        source,
        contains('_maxConcurrentDelayTestsDefault'),
        reason: 'in-process cores are not memory constrained this way',
      );
      expect(
        source.contains('const maxConcurrentDelayTests = 8'),
        isFalse,
        reason: 'the cap must not apply to every platform',
      );
    });

    test('the queue drains against the resolved limit', () {
      final source = read('lib/providers/actions/proxies.dart');
      expect(
        source,
        contains('static final _delayTestConcurrency = maxConcurrentDelayTests'),
        reason: 'a const field would not pick up the platform value',
      );
      expect(
        source,
        contains('_runningDelayTests < _delayTestConcurrency'),
        reason: 'the drain loop must still honour the limit',
      );
    });
  });

  group('provider messages are admission controlled', () {
    test('the controller bounds in-flight requests', () {
      final source = read('ios/Runner/Tunnel/TunnelController.swift');
      expect(source, contains('private let maxInFlightProviderMessages = 8'));
      expect(source, contains('private var inFlightProviderMessages = 0'));
      expect(source, contains('func acquireProviderMessageSlot() async'));
      expect(source, contains('func releaseProviderMessageSlot()'));
    });

    test('every send acquires and releases a slot', () {
      final source = read('ios/Runner/Tunnel/TunnelController.swift');
      expect(
        source,
        contains('await acquireProviderMessageSlot()'),
        reason: 'admission must happen before the request is issued',
      );
      expect(
        source,
        contains('defer { releaseProviderMessageSlot() }'),
        reason: 'a defer is what guarantees release on throw and on timeout',
      );
    });

    test('the 8 second budget is unchanged', () {
      final source = read('ios/Runner/Tunnel/TunnelController.swift');
      expect(
        source,
        contains('providerMessageTimeout: TimeInterval = 8'),
        reason: 'admission control is meant to make this budget hold, '
            'not to be replaced by a longer one',
      );
    });
  });

  group('heartbeat thresholds leave room before the death line', () {
    test('warning and reclaim sit below the observed 48 MB ceiling', () {
      final source = read('ios/NECore/NativeResourceHeartbeat.swift');
      expect(source, contains('footprintWarningMB = 30'));
      expect(source, contains('footprintReclaimMB = 38'));
    });

    test('the superseded thresholds are gone', () {
      final source = read('ios/NECore/NativeResourceHeartbeat.swift');
      expect(source.contains('footprintWarningMB = 35'), isFalse);
      expect(source.contains('footprintReclaimMB = 42'), isFalse);
    });

    test('reclaim keeps its cooldown', () {
      final source = read('ios/NECore/NativeResourceHeartbeat.swift');
      expect(
        source,
        contains('reclaimCooldown: TimeInterval = 15'),
        reason: 'a lower reclaim threshold must not turn into a per-second stall',
      );
    });
  });
}
