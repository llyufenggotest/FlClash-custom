import 'dart:io';

typedef IOSConfigPersistence = Future<void> Function(
  String path,
  String config,
);
typedef IOSTunnelOperation = Future<bool> Function();
typedef IOSActivationGuard = bool Function();

Future<void> commitAndActivateIOSConfig({
  required String configPath,
  required String config,
  required bool oldTunnelWasRunning,
  required IOSConfigPersistence persistAtomically,
  required IOSTunnelOperation stopTunnel,
  required IOSTunnelOperation startTunnel,
  IOSTunnelOperation? restoreTunnel,
  IOSActivationGuard? activationGuard,
}) async {
  void ensureCurrent() {
    if (activationGuard != null && !activationGuard()) {
      throw StateError('iOS activation request is no longer current');
    }
  }

  ensureCurrent();
  final formalConfig = File(configPath);
  final oldConfigExisted = await formalConfig.exists();
  final oldConfigBytes = oldConfigExisted
      ? await formalConfig.readAsBytes()
      : null;
  var oldTunnelStopped = false;
  var configCommitted = false;

  if (oldTunnelWasRunning) {
    ensureCurrent();
    oldTunnelStopped = await stopTunnel();
    if (!oldTunnelStopped) {
      throw StateError('old iOS tunnel did not stop');
    }
  }

  try {
    ensureCurrent();
    await persistAtomically(configPath, config);
    configCommitted = true;
    ensureCurrent();
  } catch (error) {
    if (configCommitted) {
      if (oldConfigBytes == null) {
        if (await formalConfig.exists()) {
          await formalConfig.delete();
        }
      } else {
        await _restoreConfigAtomically(configPath, oldConfigBytes);
      }
    }
    if (!oldTunnelStopped) {
      rethrow;
    }
    try {
      if (!await (restoreTunnel ?? startTunnel)()) {
        throw StateError('old iOS tunnel did not restart');
      }
    } catch (rollbackError) {
      throw StateError(
        'iOS config commit failed: $error; old tunnel recovery failed: '
        '$rollbackError',
      );
    }
    rethrow;
  }

  Object? activationError;
  try {
    if (!await startTunnel()) {
      throw StateError('new iOS tunnel did not start');
    }
    return;
  } catch (error) {
    activationError = error;
  }

  final rollbackErrors = <Object>[];
  try {
    if (!await stopTunnel()) {
      throw StateError('failed iOS tunnel did not stop');
    }
  } catch (error) {
    rollbackErrors.add(error);
  }
  try {
    if (oldConfigBytes == null) {
      if (await formalConfig.exists()) {
        await formalConfig.delete();
      }
    } else {
      await _restoreConfigAtomically(configPath, oldConfigBytes);
    }
  } catch (error) {
    rollbackErrors.add(error);
  }
  if (oldTunnelWasRunning) {
    try {
      if (!await (restoreTunnel ?? startTunnel)()) {
        throw StateError('old iOS tunnel did not restart');
      }
    } catch (error) {
      rollbackErrors.add(error);
    }
  }
  if (rollbackErrors.isNotEmpty) {
    throw StateError(
      'iOS activation failed: $activationError; rollback failed: '
      '${rollbackErrors.join('; ')}',
    );
  }
  throw activationError;
}

Future<void> _restoreConfigAtomically(String path, List<int> bytes) async {
  final temporary = File(
    '$path.rollback.$pid.${DateTime.now().microsecondsSinceEpoch}',
  );
  try {
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(path);
  } finally {
    if (await temporary.exists()) {
      await temporary.delete();
    }
  }
}
