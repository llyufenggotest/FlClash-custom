import 'dart:io';

import 'package:fl_clash/common/ios_config_activation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('iOS config activation rollback', () {
    test('failed replacement start restores bytes and old tunnel', () async {
      final directory = await Directory.systemTemp.createTemp('ios-activate-');
      addTearDown(() => directory.delete(recursive: true));
      final config = File('${directory.path}/config.yaml');
      await config.writeAsBytes([0, 1, 2, 255]);
      final events = <String>[];
      var starts = 0;

      await expectLater(
        commitAndActivateIOSConfig(
          configPath: config.path,
          config: 'new: config\n',
          oldTunnelWasRunning: true,
          persistAtomically: (path, value) async {
            events.add('commit');
            await File(path).writeAsString(value, flush: true);
          },
          stopTunnel: () async {
            events.add('stop');
            return true;
          },
          startTunnel: () async {
            starts++;
            events.add(starts == 1 ? 'start-new' : 'start-old');
            return starts > 1;
          },
        ),
        throwsA(isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('new iOS tunnel did not start'),
        )),
      );

      expect(await config.readAsBytes(), [0, 1, 2, 255]);
      expect(events, ['stop', 'commit', 'start-new', 'stop', 'start-old']);
    });

    test('failed first start restores an offline formal snapshot', () async {
      final directory = await Directory.systemTemp.createTemp('ios-activate-');
      addTearDown(() => directory.delete(recursive: true));
      final config = File('${directory.path}/config.yaml');
      await config.writeAsString('old: offline\n');
      final events = <String>[];

      await expectLater(
        commitAndActivateIOSConfig(
          configPath: config.path,
          config: 'new: config\n',
          oldTunnelWasRunning: false,
          persistAtomically: (path, value) async {
            events.add('commit');
            await File(path).writeAsString(value, flush: true);
          },
          stopTunnel: () async {
            events.add('stop');
            return true;
          },
          startTunnel: () async {
            events.add('start-new');
            return false;
          },
        ),
        throwsA(isA<StateError>()),
      );

      expect(await config.readAsString(), 'old: offline\n');
      expect(events, ['commit', 'start-new', 'stop']);
    });

    test('failed first start removes a newly-created formal config', () async {
      final directory = await Directory.systemTemp.createTemp('ios-activate-');
      addTearDown(() => directory.delete(recursive: true));
      final config = File('${directory.path}/config.yaml');

      await expectLater(
        commitAndActivateIOSConfig(
          configPath: config.path,
          config: 'new: config\n',
          oldTunnelWasRunning: false,
          persistAtomically: (path, value) =>
              File(path).writeAsString(value, flush: true),
          stopTunnel: () async => true,
          startTunnel: () async => false,
        ),
        throwsA(isA<StateError>()),
      );

      expect(await config.exists(), isFalse);
    });

    test('reports activation and rollback failures together', () async {
      final directory = await Directory.systemTemp.createTemp('ios-activate-');
      addTearDown(() => directory.delete(recursive: true));
      final config = File('${directory.path}/config.yaml');
      await config.writeAsString('old: config\n');
      var stops = 0;

      await expectLater(
        commitAndActivateIOSConfig(
          configPath: config.path,
          config: 'new: config\n',
          oldTunnelWasRunning: true,
          persistAtomically: (path, value) =>
              File(path).writeAsString(value, flush: true),
          stopTunnel: () async {
            stops++;
            return stops == 1;
          },
          startTunnel: () async => false,
        ),
        throwsA(isA<StateError>()
            .having((error) => error.message, 'message',
                contains('new iOS tunnel did not start'))
            .having((error) => error.message, 'message',
                contains('failed iOS tunnel did not stop'))),
      );
      expect(await config.readAsString(), 'old: config\n');
      expect(stops, 2);
    });
  });
}
