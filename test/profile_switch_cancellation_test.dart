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
