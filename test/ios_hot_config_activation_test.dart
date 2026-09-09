import 'dart:io';

import 'package:fl_clash/common/ios_config_activation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('iOS hot config activation', () {
    test('commits and applies without a tunnel lifecycle operation', () async {
      final directory = await Directory.systemTemp.createTemp('ios-hot-apply-');
      addTearDown(() => directory.delete(recursive: true));
      final config = File('${directory.path}/config.yaml');
      await config.writeAsString('old: config\n');
      final events = <String>[];

      await commitAndHotApplyIOSConfig(
        configPath: config.path,
        config: 'new: config\n',
        persistAtomically: (path, value) async {
          events.add('commit');
          await File(path).writeAsString(value, flush: true);
        },
        applyConfig: () async {
          events.add('apply-new');
          return '';
        },
        restoreConfig: () async {
          events.add('apply-old');
          return '';
        },
      );

      expect(events, ['commit', 'apply-new']);
      expect(await config.readAsString(), 'new: config\n');
    });

    test(
      'failed hot apply restores bytes and reapplies the old config',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'ios-hot-rollback-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final config = File('${directory.path}/config.yaml');
        await config.writeAsString('old: config\n');
        final events = <String>[];

        await expectLater(
          commitAndHotApplyIOSConfig(
            configPath: config.path,
            config: 'new: config\n',
            persistAtomically: (path, value) async {
              events.add('commit');
              await File(path).writeAsString(value, flush: true);
            },
            applyConfig: () async {
              events.add('apply-new');
              return 'invalid new config';
            },
            restoreConfig: () async {
              events.add('apply-old');
              return '';
            },
          ),
          throwsA(isA<StateError>()),
        );

        expect(events, ['commit', 'apply-new', 'apply-old']);
        expect(await config.readAsString(), 'old: config\n');
      },
    );

    test('stale request cannot commit', () async {
      final directory = await Directory.systemTemp.createTemp('ios-hot-guard-');
      addTearDown(() => directory.delete(recursive: true));
      final config = File('${directory.path}/config.yaml');
      await config.writeAsString('old: config\n');
      var applied = false;

      await expectLater(
        commitAndHotApplyIOSConfig(
          configPath: config.path,
          config: 'new: config\n',
          activationGuard: () => false,
          persistAtomically: (path, value) =>
              File(path).writeAsString(value, flush: true),
          applyConfig: () async {
            applied = true;
            return '';
          },
          restoreConfig: () async => '',
        ),
        throwsA(isA<StateError>()),
      );

      expect(applied, isFalse);
      expect(await config.readAsString(), 'old: config\n');
    });
  });
}
