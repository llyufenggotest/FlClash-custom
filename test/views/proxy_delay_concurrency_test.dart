import 'dart:async';

import 'package:fl_clash/views/proxies/common.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bulk delay tests never exceed the configured concurrency', () async {
    var active = 0;
    var maxActive = 0;
    final completed = <int>[];

    await runWithConcurrencyLimit(
      List<int>.generate(57, (index) => index),
      concurrency: proxyDelayTestConcurrency,
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

    expect(maxActive, lessThanOrEqualTo(proxyDelayTestConcurrency));
    expect(completed, hasLength(57));
    expect(completed.toSet(), hasLength(57));
  });
}
