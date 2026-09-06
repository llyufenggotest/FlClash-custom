import 'dart:async';

import 'package:fl_clash/core/rule_preparation_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reuses only one in-flight operation for the same identity', () async {
    final scheduler = RulePreparationScheduler();
    final completer = Completer<String>();
    var invocations = 0;

    Future<String> prepare() {
      invocations++;
      return completer.future;
    }

    final first = scheduler.prepare('profile|sha256', prepare);
    final second = scheduler.prepare('profile|sha256', prepare);
    expect(invocations, 1);
    completer.complete('');
    expect(await first, '');
    expect(await second, '');
  });

  test('completed work is not retained as durable readiness', () async {
    final scheduler = RulePreparationScheduler();
    var invocations = 0;
    for (var i = 0; i < 2; i++) {
      expect(
        await scheduler.prepare('profile|sha256', () async {
          invocations++;
          return '';
        }),
        '',
      );
    }
    expect(invocations, 2);
  });

  test('failed and throwing work can be retried', () async {
    final scheduler = RulePreparationScheduler();
    expect(await scheduler.prepare('k', () async => 'failed'), 'failed');
    final throwing = scheduler.prepare(
      'x',
      () async => throw StateError('broken'),
    );
    await expectLater(throwing, throwsStateError);
    expect(await scheduler.prepare('k', () async => ''), '');
  });
}
