import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String source(String path) =>
      File(path).readAsStringSync().replaceAll('\r\n', '\n');

  group('iOS prepared config commit', () {
    test(
      'shared config is not overwritten before preparation and admission',
      () {
        final setup = source('lib/providers/actions/setup.dart');
        final loadingStart = setup.indexOf('await globalState.loadingRun(');
        final loadingEnd = setup.indexOf(
          'return _SetupTaskResult.completed;',
          loadingStart,
        );
        expect(loadingStart, greaterThan(-1));
        expect(loadingEnd, greaterThan(loadingStart));
        final body = setup.substring(loadingStart, loadingEnd);

        expect(body, contains('if (!system.isIOS)'));
        expect(
          body,
          isNot(
            contains(
              'persistPreparedConfig: (preparedConfig) =>\n'
              '              File(configFilePath).safeWriteAsString('
              'preparedConfig)',
            ),
          ),
          reason:
              'the generation prepare callback must not publish config.yaml',
        );
      },
    );

    test('prepared YAML path is retained until Runner admits it', () {
      final controller = source('lib/core/controller.dart');
      final setup = source('lib/providers/actions/setup.dart');
      expect(
        controller,
        contains('candidateConfigPath = prepared.configPath;'),
      );
      expect(
        controller,
        contains(
          'result = await _interface.validateCandidateConfigAtPath(path);',
        ),
      );
      expect(
        controller.indexOf('candidateConfigPath = prepared.configPath;'),
        lessThan(
          controller.indexOf(
            'result = await _interface.validateCandidateConfigAtPath(path);',
          ),
        ),
      );
      expect(
        setup,
        contains(
          'preloadInvoke: system.isIOS ? commitAndActivate : preloadInvoke',
        ),
        reason:
            'an iOS apply must force the controller through Runner admission '
            'even when there is no extension start callback',
      );
    });

    test('validated config is committed before formal apply and startup', () {
      final setup = source('lib/providers/actions/setup.dart');
      final start = setup.indexOf('Future<void> commitAndActivate()');
      expect(start, greaterThan(-1));
      final end = setup.indexOf('\n          final message =', start);
      expect(end, greaterThan(start));
      final body = setup.substring(start, end);

      final activationAt = body.indexOf('commitAndActivateIOSConfig(');
      final commitAt = body.indexOf(
        'persistAtomically: _persistConfigAtomically',
        activationAt,
      );
      final stopAt = body.indexOf(
        'stopTunnel: () => setCoreRunning(false)',
        activationAt,
      );
      final startAt = body.indexOf('startTunnel: () async', activationAt);
      final startBody = body.substring(startAt);
      final applyAt = startBody.indexOf(
        'final applyResult = await applyFormalConfig()',
      );
      expect(activationAt, greaterThan(-1));
      expect(commitAt, greaterThan(activationAt));
      expect(stopAt, greaterThan(commitAt));
      expect(startAt, greaterThan(stopAt));
      expect(applyAt, greaterThan(-1));
      final restoreAt = body.indexOf('restoreTunnel: () async');
      final restoreEnd = body.indexOf('startTunnel: () async', restoreAt);
      final restoreBody = body.substring(restoreAt, restoreEnd);
      expect(restoreAt, greaterThan(stopAt));
      final restoreApplyAt = restoreBody.indexOf(
        'final restoreResult = await applyFormalConfig()',
      );
      final restoreStartAt = restoreBody.indexOf(
        'return setCoreRunning(true);',
      );
      expect(restoreApplyAt, greaterThan(-1));
      expect(restoreStartAt, greaterThan(-1));
      expect(restoreApplyAt, lessThan(restoreStartAt));
      final helper = source('lib/common/ios_config_activation.dart');
      expect(
        helper.indexOf('final oldConfigBytes ='),
        lessThan(helper.indexOf('await persistAtomically(configPath, config)')),
      );
      expect(helper, contains("StateError('failed iOS tunnel did not stop')"));
      expect(helper, contains("StateError('old iOS tunnel did not restart')"));
    });

    test('atomic persistence uses a same-directory temporary and rename', () {
      final setup = source('lib/providers/actions/setup.dart');
      final start = setup.indexOf('Future<void> _persistConfigAtomically(');
      expect(start, greaterThan(-1));
      final end = setup.indexOf(
        '\n  Future<_SetupTaskResult> _setupConfig(',
        start,
      );
      expect(end, greaterThan(start));
      final body = setup.substring(start, end);

      expect(
        body,
        contains(r"'$path.tmp.$pid.${DateTime.now().microsecondsSinceEpoch}'"),
      );
      expect(body, contains('writeAsString(config, flush: true)'));
      expect(body, contains('await temporary.rename(path)'));
      expect(body, contains('await temporary.safeDelete()'));
    });
  });
}
