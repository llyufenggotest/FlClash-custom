import 'dart:io';

import 'package:fl_clash/common/lock.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('flclash_lock_test_');
  });

  tearDown(() {
    directory.deleteSync(recursive: true);
  });

  test('reuses a stale lock file when no process owns it', () async {
    final path = '${directory.path}/FlClash.lock';
    File(path).writeAsStringSync('stale lock marker');
    final lock = SingleInstanceLock(pathProvider: () async => path);

    expect(await lock.acquire(), isTrue);
    await lock.release();
  });

  test('keeps a second process from acquiring the same lock', () async {
    final path = '${directory.path}/FlClash.lock';
    final first = SingleInstanceLock(pathProvider: () async => path);
    final second = SingleInstanceLock(pathProvider: () async => path);

    expect(await first.acquire(), isTrue);
    expect(await second.acquire(), isFalse);
    await first.release();
    await second.release();
  });
}
