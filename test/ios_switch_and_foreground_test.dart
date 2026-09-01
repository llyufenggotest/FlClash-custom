import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Source-level contracts for the two defects the 2026-09-01 device trace
/// (`FlClash_2026-09-01.log`, 6475 lines) pinned down.
///
/// 1. `CoreMethodException(empty_response, ...)` still surfaced when switching
///    subscriptions. The trace shows all 52 `provider message empty` entries
///    arriving in 6 bursts, each burst immediately after a tunnel restart while
///    the extension was mid-reload:
///
///      03:20:43 running completed actual=running generation=3
///      03:20:43 NECore quickSetup -> Finished initial GeoSite rule cn, records: 111197
///      03:20:43 NECore memory_pressure_warning footprint_mb=33 threshold_mb=30
///      03:20:44 NECore memory_pressure_reclaim footprint_mb=42 threshold_mb=38
///      03:20:45 provider message empty seq=143 bytes=171 duration_ms=650
///
///    The tunnel was `.running`, so gating on tunnel state alone could not stop
///    it. A nil reply from a running-but-busy extension is a retry signal.
///
/// 2. The proxies tab disappeared after a background/foreground round trip while
///    traffic kept flowing. `groups` is in-memory only, and the
///    `skipRedundantReload` fast path returned before `onUpdated`, so the list
///    was never refilled — the data was never lost, the derived UI state was
///    simply never populated.
void main() {
  String source(String path) => File(path).readAsStringSync();

  group('a busy extension is retried, not reported as a failure', () {
    test('nil replies from a running tunnel use the retryable marker', () {
      final controller = source('ios/Runner/Tunnel/TunnelController.swift');
      expect(controller, contains('emptyReplyRetryCode'));
      expect(controller, contains('provider message empty-busy'));
      expect(
        controller,
        contains('code: retryCode'),
        reason: 'a running-but-busy extension must not raise empty_response',
      );
    });

    test('the retry loop is bounded and backs off', () {
      final controller = source('ios/Runner/Tunnel/TunnelController.swift');
      expect(controller, contains('emptyReplyRetryLimit = 3'));
      expect(controller, contains('emptyReplyRetryBackoff'));
      expect(controller, contains('Task.sleep(nanoseconds: backoff)'));
      expect(controller, contains('for attempt in 1...emptyReplyRetryLimit'));
    });

    test('exhausting the retries reports the terminal code once', () {
      final controller = source('ios/Runner/Tunnel/TunnelController.swift');
      final loopStart = controller.indexOf('guard attempt < emptyReplyRetryLimit');
      expect(loopStart, greaterThan(-1));
      final guardBody = controller.substring(loopStart, loopStart + 400);
      expect(guardBody, contains("code: \"empty_response\""));
      expect(guardBody, contains('provider message empty seq='));
    });

    test('the admission slot is held across retries', () {
      final controller = source('ios/Runner/Tunnel/TunnelController.swift');
      final send = controller.indexOf('func sendProviderMessage(');
      final attempt = controller.indexOf('func sendProviderMessageAttempt(');
      expect(send, greaterThan(-1));
      expect(attempt, greaterThan(send));
      final body = controller.substring(send, attempt);
      expect(body, contains('await acquireProviderMessageSlot()'));
      expect(body, contains('defer { releaseProviderMessageSlot() }'));
    });

    test('a stop-time nil reply stays benign', () {
      final controller = source('ios/Runner/Tunnel/TunnelController.swift');
      expect(controller, contains('provider message dropped-on-stop'));
      expect(controller, contains('code: "network_extension_unavailable"'));
    });
  });

  group('transient core unavailability never reaches the user', () {
    test('the unavailable set covers the extension-teardown code', () {
      final method = source('lib/core/method.dart');
      expect(method, contains("'network_extension_unavailable'"));
      expect(method, contains('bool isCoreUnavailableError('));
    });

    test('loadingRun swallows core-unavailable failures', () {
      final state = source('lib/state.dart');
      final catchStart = state.indexOf("commonPrint.log('\$title ===> \$e, \$s'");
      expect(catchStart, greaterThan(-1));
      final body = state.substring(catchStart, catchStart + 500);
      expect(
        body.indexOf('isCoreUnavailableError(e)'),
        lessThan(body.indexOf('showNotifier(e.toString()')),
        reason: 'the guard must run before the notifier',
      );
    });
  });

  group('the proxies tab survives a foreground return', () {
    test('the skip fast path still refreshes the group list', () {
      final setup = source('lib/providers/actions/setup.dart');
      final skipStart = setup.indexOf('if (skipRedundantReload) {');
      expect(skipStart, greaterThan(-1));
      final skipEnd = setup.indexOf('return _SetupTaskResult.completed', skipStart);
      expect(skipEnd, greaterThan(skipStart));
      final skipBody = setup.substring(skipStart, skipEnd);
      expect(
        skipBody,
        contains('await onUpdated?.call()'),
        reason: 'skipping the config push must not skip refilling the UI',
      );
      expect(skipBody, contains('await preloadInvoke?.call()'));
    });

    test('onUpdated is what reloads the groups', () {
      final setup = source('lib/providers/actions/setup.dart');
      final onUpdated = setup.indexOf('onUpdated: () async {');
      expect(onUpdated, greaterThan(-1));
      final body = setup.substring(onUpdated, onUpdated + 260);
      expect(body, contains('updateGroups()'));
    });

    test('a transient empty or failed refresh keeps the last known groups', () {
      final proxies = source('lib/providers/actions/proxies.dart');
      expect(proxies, contains('ignoring transient empty result'));
      final catchStart = proxies.indexOf("'updateGroups error: \$e'");
      expect(catchStart, greaterThan(-1));
      final tail = proxies.substring(catchStart);
      final nextMethod = tail.indexOf('void _removeUnavailableSelections');
      expect(nextMethod, greaterThan(-1));
      expect(
        tail.substring(0, nextMethod),
        isNot(contains('.value = []')),
        reason: 'clearing groups on a transient error hid the whole tab',
      );
    });

    test('the tab is derived from the group list, so it must stay filled', () {
      final state = source('lib/providers/state.dart');
      expect(state, contains('final hasProxies = ref.watch('));
      expect(state, contains('currentGroupsStateProvider.select'));
    });
  });
}
