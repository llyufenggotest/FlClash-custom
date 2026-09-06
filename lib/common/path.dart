import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path_provider_foundation/path_provider_foundation.dart';

class AppPath {
  static AppPath? _instance;
  Completer<Directory> dataDir = Completer();
  Completer<Directory> supportDir = Completer();
  late final Future<Directory?> _downloadDir = getDownloadsDirectory();
  Completer<Directory> tempDir = Completer();
  Completer<Directory> cacheDir = Completer();
  late String appDirPath;
  late final bool isPortable =
      (system.isWindows || system.isLinux) &&
      Directory(join(appDirPath, 'config')).existsSync();

  AppPath._internal() {
    appDirPath = join(dirname(Platform.resolvedExecutable));
    _initDataDir();
    _initTempDir();
    _initCacheDir();
  }

  factory AppPath() {
    _instance ??= AppPath._internal();
    return _instance!;
  }

  Future<void> _initDataDir() async {
    if (isPortable) {
      dataDir.complete(Directory(join(appDirPath, 'config')));
      return;
    }
    final applicationSupportDir = await getApplicationSupportDirectory();
    supportDir.complete(applicationSupportDir);
    try {
      if (!system.isIOS) {
        dataDir.complete(applicationSupportDir);
        return;
      }

      final appGroupPath = await _getIOSAppGroupPath();
      if (appGroupPath.isEmpty) {
        dataDir.complete(applicationSupportDir);
        return;
      }

      final appGroupDir = Directory(appGroupPath);
      await appGroupDir.create(recursive: true);
      await _copyDirectoryContentsIfMissing(applicationSupportDir, appGroupDir);
      dataDir.complete(appGroupDir);
    } catch (_) {
      dataDir.complete(applicationSupportDir);
    }
  }

  Future<void> _initCacheDir() async {
    await dataDir.future;
    if (isPortable) {
      cacheDir.complete(Directory(join(await homeDirPath, '.cache')));
      return;
    }
    final dir = await getApplicationCacheDirectory();
    cacheDir.complete(dir);
  }

  Future<void> _initTempDir() async {
    await dataDir.future;
    if (isPortable) {
      final portableTmpDir = Directory(join(await homeDirPath, 'tmp'));
      if (await portableTmpDir.exists()) {
        tempDir.complete(portableTmpDir);
        return;
      }
    }
    final dir = await getTemporaryDirectory();
    tempDir.complete(dir);
  }

  Future<String> _getIOSAppGroupPath() async {
    try {
      final PackageInfo packageInfo = await PackageInfo.fromPlatform();
      return await PathProviderFoundation().getContainerPath(
            appGroupIdentifier: 'group.${packageInfo.packageName}',
          ) ??
          '';
    } catch (_) {
      return '';
    }
  }

  Future<void> _copyDirectoryContentsIfMissing(
    Directory source,
    Directory target,
  ) async {
    if (!await source.exists()) {
      return;
    }
    if (equals(source.path, target.path)) {
      return;
    }
    await for (final entity in source.list(recursive: true)) {
      final relativePath = relative(entity.path, from: source.path);
      final targetPath = join(target.path, relativePath);
      if (entity is Directory) {
        await Directory(targetPath).create(recursive: true);
        continue;
      }
      if (entity is! File || await File(targetPath).exists()) {
        continue;
      }
      await File(targetPath).parent.create(recursive: true);
      await entity.copy(targetPath);
    }
  }

  String get executableExtension {
    return system.isWindows ? '.exe' : '';
  }

  String get executableDirPath {
    final currentExecutablePath = Platform.resolvedExecutable;
    return dirname(currentExecutablePath);
  }

  String get corePath {
    return join(executableDirPath, 'FlClashCore$executableExtension');
  }

  String get helperPath {
    return join(executableDirPath, '$appHelperService$executableExtension');
  }

  Future<String> get downloadDirPath async {
    final directory = await _downloadDir;
    return directory?.path ?? await homeDirPath;
  }

  Future<String> get homeDirPath async {
    final directory = await dataDir.future;
    return directory.path;
  }

  Future<String> get databasePath async {
    if (system.isIOS) {
      return join((await supportDir.future).path, 'database.sqlite');
    }
    final mHomeDirPath = await homeDirPath;
    return join(mHomeDirPath, 'database.sqlite');
  }

  Future<String> get backupFilePath async {
    final mHomeDirPath = await homeDirPath;
    return join(mHomeDirPath, 'backup.zip');
  }

  Future<String> get restoreDirPath async {
    final mHomeDirPath = await homeDirPath;
    return join(mHomeDirPath, 'restore');
  }

  Future<String> get tempFilePath async {
    final mTempDir = await tempDir.future;
    return join(mTempDir.path, 'temp${utils.id}');
  }

  Future<String> get configFilePath async {
    final mHomeDirPath = await homeDirPath;
    return join(mHomeDirPath, 'config.yaml');
  }

  Future<String> get sharedFilePath async {
    final mHomeDirPath = await homeDirPath;
    return join(mHomeDirPath, 'shared.json');
  }

  Future<String> get sharedPreferencesPath async {
    final directory = await dataDir.future;
    return join(directory.path, 'shared_preferences.json');
  }

  Future<String> get profilesPath async {
    final directory = await dataDir.future;
    return join(directory.path, profilesDirectoryName);
  }

  Future<String> getProfilePath(String fileName) async {
    return join(await profilesPath, '$fileName.yaml');
  }

  Future<String> get scriptsDirPath async {
    final path = await homeDirPath;
    return join(path, 'scripts');
  }

  Future<String> getScriptPath(String fileName) async {
    final path = await scriptsDirPath;
    return join(path, '$fileName.js');
  }

  Future<String> getIconsCacheDir() async {
    final directory = await cacheDir.future;
    return join(directory.path, 'icons');
  }

  Future<String> getProvidersRootPath() async {
    final directory = await profilesPath;
    return join(directory, 'providers');
  }

  Future<String> getProvidersDirPath(String id) async {
    final directory = await profilesPath;
    return join(directory, 'providers', id);
  }

  Future<String> getProvidersFilePath(
    String id,
    String type,
    String url,
  ) async {
    final directory = await profilesPath;
    return join(directory, 'providers', id, type, url.toMd5());
  }

  Future<String> get tempPath async {
    final directory = await tempDir.future;
    return directory.path;
  }
}

final appPath = AppPath();
