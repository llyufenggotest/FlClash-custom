import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS RPC production receiver behavior', () async {
    final result = await Process.run('python3', ['test/ios_rpc/run.py']);
    expect(result.exitCode, 0,
        reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('IOS_RPC_BEHAVIOR_PASS'));
    expect(result.stdout, contains('IOS_NATIVE_MTU_BEHAVIOR_PASS'));
  },
      skip: !Platform.isMacOS
          ? 'Requires macOS Swift/Darwin; do not replace with source-string checks'
          : false);
}
