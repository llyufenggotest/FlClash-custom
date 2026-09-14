import 'dart:async';

import 'package:fl_clash/core/controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('A to B to A late futures cannot publish another activation', () async {
    final ownership = ActivationEpochOwnership();
    final firstA = ownership.begin();
    expect(ownership.activate(firstA), isTrue);

    final firstAResult = Completer<String>();
    final published = <String>[];
    final lateFirstA = firstAResult.future.then((value) {
      ownership.publishIfOwned(firstA, () => published.add(value));
    });

    final b = ownership.begin();
    expect(ownership.activate(b), isTrue);
    final lateBResult = Completer<String>();
    final lateB = lateBResult.future.then((value) {
      ownership.publishIfOwned(b, () => published.add(value));
    });

    final secondA = ownership.begin();
    expect(ownership.activate(secondA), isTrue);
    ownership.publishIfOwned(secondA, () => published.add('new A'));

    lateBResult.complete('old B');
    firstAResult.complete('old A');
    await Future.wait([lateFirstA, lateB]);

    expect(published, ['new A']);
  });

  test(
    'a failed newer activation cannot restore old publication ownership',
    () {
      final ownership = ActivationEpochOwnership();
      final active = ownership.begin();
      expect(ownership.activate(active), isTrue);

      final failed = ownership.begin();
      expect(ownership.activate(failed - 1), isFalse);
      expect(ownership.owns(active), isFalse);
      expect(ownership.owns(failed), isFalse);
    },
  );

  test('empty snapshots are publishable values', () {
    final ownership = ActivationEpochOwnership();
    final epoch = ownership.begin();
    expect(ownership.activate(epoch), isTrue);
    var visible = <String>['old'];

    expect(
      ownership.publishIfOwned(epoch, () => visible = const <String>[]),
      isTrue,
    );
    expect(visible, isEmpty);
  });
}
