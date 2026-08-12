import 'dart:async';

import 'package:fl_clash/views/proxies/common.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bulk delay tests never exceed the configured concurrency', () async {
    var active = 0;
    var maxActive = 0;
    final completed = <int>[];

    await runWithConcurrencyLimit(
      List<int>.generate(37, (index) => index),
      concurrency: 10,
      action: (item) async {
        active += 1;
        if (active > maxActive) {
          maxActive = active;
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
        completed.add(item);
        active -= 1;
      },
    );

    expect(maxActive, lessThanOrEqualTo(10));
    expect(completed, hasLength(37));
    expect(completed.toSet(), hasLength(37));
  });
}
