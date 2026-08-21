import 'dart:io';

import 'package:fl_clash/common/common.dart';

class SingleInstanceLock {
  static SingleInstanceLock? _instance;
  RandomAccessFile? _accessFile;
  final Future<String> Function() _pathProvider;

  SingleInstanceLock._internal({Future<String> Function()? pathProvider})
    : _pathProvider = pathProvider ?? (() => appPath.lockFilePath);

  factory SingleInstanceLock({Future<String> Function()? pathProvider}) {
    if (pathProvider != null) {
      return SingleInstanceLock._internal(pathProvider: pathProvider);
    }
    _instance ??= SingleInstanceLock._internal();
    return _instance!;
  }

  Future<bool> acquire() async {
    RandomAccessFile? accessFile;
    try {
      final lockFile = File(await _pathProvider());
      await lockFile.parent.create(recursive: true);
      // Opening an existing file is intentional: the file's existence does
      // not mean another FlClash process still owns the OS-level lock.
      accessFile = await lockFile.open(mode: FileMode.append);
      await accessFile.lock(FileLock.exclusive);
      _accessFile = accessFile;
      return true;
    } catch (_) {
      await accessFile?.close();
      return false;
    }
  }

  Future<void> release() async {
    final accessFile = _accessFile;
    _accessFile = null;
    await accessFile?.unlock();
    await accessFile?.close();
  }
}

final singleInstanceLock = SingleInstanceLock();
