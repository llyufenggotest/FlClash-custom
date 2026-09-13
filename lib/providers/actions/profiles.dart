part of '../action.dart';

@Riverpod(keepAlive: true)
class ProfilesAction extends _$ProfilesAction {
  CoreController get _core => ref.read(coreHandlerProvider);

  final Map<int, int> _profileUpdateGenerations = {};
  final Map<int, Future<void>> _profileTransactionTails = {};

  Future<void> _withProfileTransaction(
    int profileId,
    Future<void> Function() action,
  ) async {
    final previous = _profileTransactionTails[profileId] ?? Future<void>.value();
    final completer = Completer<void>();
    _profileTransactionTails[profileId] = completer.future;
    try {
      await previous.catchError((_) {});
      await action();
    } finally {
      completer.complete();
      if (identical(_profileTransactionTails[profileId], completer.future)) {
        _profileTransactionTails.remove(profileId);
      }
    }
  }

  Future<T> withProfileTransaction<T>(
    int profileId,
    Future<T> Function() action,
  ) async {
    late T result;
    await _withProfileTransaction(profileId, () async {
      result = await action();
    });
    return result;
  }

  Future<void> ensureProfileFile(Profile profile) async {
    final path = await appPath.getProfilePath(profile.id.toString());
    if (await File(path).exists() || profile.url.isEmpty) return;
    await updateProfile(profile);
  }

  int _beginProfileUpdate(int profileId) => _profileUpdateGenerations.update(
    profileId,
    (value) => value + 1,
    ifAbsent: () => 1,
  );

  bool _isCurrentProfileUpdate(int profileId, int generation) =>
      _profileUpdateGenerations[profileId] == generation;

  @override
  void build() {}

  void updateCurrentSelectedMap(String groupName, String proxyName) {
    final currentProfile = ref.read(currentProfileProvider);
    if (currentProfile != null &&
        currentProfile.selectedMap[groupName] != proxyName) {
      final selectedMap = Map<String, String>.from(currentProfile.selectedMap)
        ..[groupName] = proxyName;
      ref
          .read(profilesProvider.notifier)
          .put(currentProfile.copyWith(selectedMap: selectedMap));
    }
  }

  Future<void> deleteProfile(int id) async {
    _beginProfileUpdate(id);
    await _withProfileTransaction(id, () async {
      final oldProfile = ref.read(profilesProvider).getProfile(id);
      if (oldProfile == null) return;
      final profilePath = await appPath.getProfilePath(id.toString());
      final profileFile = File(profilePath);
      final backup = File(
        '$profilePath.delete-rollback.$pid.${DateTime.now().microsecondsSinceEpoch}',
      );
      final hadFile = await profileFile.exists();
      if (hadFile) await profileFile.copy(backup.path);
      var preserveBackup = false;
      try {
        if (hadFile) await profileFile.safeDelete();
        await ref.read(profilesProvider.notifier).del(id);
      } catch (error, stackTrace) {
        try {
          if (hadFile && await backup.exists()) {
            await backup.rename(profilePath);
          }
          await ref.read(profilesProvider.notifier).putAsync(oldProfile);
        } catch (restoreError, restoreStack) {
          preserveBackup = hadFile && await backup.exists();
          Error.throwWithStackTrace(
            StateError(
              'profile deletion failed ($error); rollback failed '
              '($restoreError); preserved backup: ${backup.path}',
            ),
            restoreStack,
          );
        }
        Error.throwWithStackTrace(error, stackTrace);
      } finally {
        if (!preserveBackup) await backup.safeDelete();
      }
      try {
        await clearProviderEffect(id);
      } catch (error) {
        commonPrint.log(
          'profile $id deleted; deferred provider cleanup failed: $error',
          logLevel: LogLevel.warning,
        );
      }
      final currentProfileId = ref.read(currentProfileIdProvider);
      if (currentProfileId == id) {
        final profiles = ref.read(profilesProvider);
        if (profiles.isNotEmpty) {
          final updateId = profiles.first.id;
          ref.read(currentProfileIdProvider.notifier).value = updateId;
        } else {
          ref.read(currentProfileIdProvider.notifier).value = null;
          unawaited(ref.read(setupActionProvider.notifier).setRunning(false));
        }
      }
    });
  }

  Future<String> validateConfigWithData(String data) async {
    return _core.validateConfigWithData(data);
  }

  Future<String> prepareProfileConfig(
    String content,
    String? ageSecretKey,
  ) async {
    var prepared = convertFastupSubscription(content);
    if (ageSecretKey?.isNotEmpty == true) {
      final decrypted = await _core.decryptAgeConfig(prepared, ageSecretKey!);
      if (decrypted.isNotEmpty) {
        prepared = decrypted;
      }
    }
    final message = await _core.validateConfig(prepared);
    if (message.isNotEmpty) {
      throw MessageException(message);
    }
    return prepared;
  }

  Future<void> autoUpdateProfiles() async {
    for (final profile in ref.read(profilesProvider)) {
      if (!profile.autoUpdate) continue;
      final isNotNeedUpdate = profile.lastUpdateDate
          ?.add(profile.autoUpdateDuration)
          .isBeforeNow;
      if (isNotNeedUpdate == false || profile.type == ProfileType.file) {
        continue;
      }
      try {
        await updateProfile(profile);
      } catch (e) {
        commonPrint.log(compactError(e), logLevel: LogLevel.warning);
      }
    }
  }

  Future<void> _commitPreparedProfile({
    required Profile profile,
    required String candidateYaml,
    required bool isNew,
    bool Function()? commitGuard,
  }) async {
    await _withProfileTransaction(profile.id, () async {
      if (commitGuard != null && !commitGuard()) return;
      final setupAction = ref.read(setupActionProvider.notifier);
      final preparation = await setupAction.prewarmProfile(
        profile,
        candidateYaml: candidateYaml,
        allowUncommittedProfile: isNew,
      );
      if (commitGuard != null && !commitGuard()) return;
      final target = File(await appPath.getProfilePath(profile.id.toString()));
      await target.parent.create(recursive: true);
      final temporary = File(
        '${target.path}.candidate.$pid.${DateTime.now().microsecondsSinceEpoch}',
      );
      final backup = File(
        '${target.path}.rollback.$pid.${DateTime.now().microsecondsSinceEpoch}',
      );
      final hadOld = await target.exists();
      final oldProfile = ref.read(profilesProvider).getProfile(profile.id);
      var preserveBackup = false;
      var activationAttempted = false;
      try {
        await temporary.writeAsString(candidateYaml, flush: true);
        if (hadOld) await target.copy(backup.path);
        if (commitGuard != null && !commitGuard()) return;
        await temporary.rename(target.path);
        try {
          await ref.read(profilesProvider.notifier).putAsync(profile);
          if (commitGuard != null && !commitGuard()) {
            throw StateError('profile commit is no longer current');
          }
          if (preparation != null) {
            activationAttempted = true;
            await _core.activateRuleGeneration(
              profileId: profile.id,
              preparation: preparation,
            );
          }
        } catch (error, stackTrace) {
          try {
            if (activationAttempted && preparation != null) {
              await _core.restoreRuleGeneration(
                profileId: profile.id,
                failedGeneration: preparation.generation,
              );
            }
            if (hadOld) {
              await backup.rename(target.path);
            } else {
              await target.safeDelete();
            }
            if (oldProfile != null) {
              await ref.read(profilesProvider.notifier).putAsync(oldProfile);
            } else {
              await ref.read(profilesProvider.notifier).del(profile.id);
            }
          } catch (restoreError, restoreStack) {
            preserveBackup = hadOld && await backup.exists();
            Error.throwWithStackTrace(
              StateError(
                'profile commit failed ($error); rollback failed '
                '($restoreError); preserved backup: ${backup.path}',
              ),
              restoreStack,
            );
          }
          Error.throwWithStackTrace(error, stackTrace);
        }
        if (isNew && ref.read(currentProfileIdProvider) == null) {
          ref.read(currentProfileIdProvider.notifier).value = profile.id;
        }
      } finally {
        await temporary.safeDelete();
        if (!preserveBackup) await backup.safeDelete();
      }
    });
  }

  Future<void> putPreparedProfile(
    Profile profile,
    String candidateYaml,
  ) {
    final existing = ref.read(profilesProvider).getProfile(profile.id);
    return _commitPreparedProfile(
      profile: profile,
      candidateYaml: candidateYaml,
      isNew: existing == null,
      commitGuard: existing == null
          ? () => ref.read(profilesProvider).getProfile(profile.id) == null
          : () => identical(
              ref.read(profilesProvider).getProfile(profile.id),
              existing,
            ),
    );
  }

  void putProfile(Profile profile) {
    ref.read(profilesProvider.notifier).put(profile);
    if (ref.read(currentProfileIdProvider) == null) {
      ref.read(currentProfileIdProvider.notifier).value = profile.id;
    }
  }

  Future<void> updateProfiles() async {
    for (final profile in ref.read(profilesProvider)) {
      if (profile.type == ProfileType.file) continue;
      await updateProfile(profile);
    }
  }

  Future<void> updateProfile(
    Profile profile, {
    bool showLoading = false,
  }) async {
    final operation = showLoading
        ? ref.read(updatingKeysProvider.notifier).start(profile.updatingKey)
        : null;
    final generation = _beginProfileUpdate(profile.id);
    try {
      final prepared = await profile.prepareUpdate(
        prepare: prepareProfileConfig,
        commitGuard: () => _isCurrentProfileUpdate(profile.id, generation),
      );
      if (!_isCurrentProfileUpdate(profile.id, generation) ||
          prepared.content.isEmpty) {
        return;
      }
      await _commitPreparedProfile(
        profile: prepared.profile,
        candidateYaml: prepared.content,
        isNew: false,
        commitGuard: () => _isCurrentProfileUpdate(profile.id, generation),
      );
    } finally {
      if (operation != null) {
        ref
            .read(updatingKeysProvider.notifier)
            .stop(profile.updatingKey, operation);
      }
    }
  }

  Future<void> _addPreparedProfile({
    required Future<PreparedProfileContent> Function() futureFunction,
  }) async {
    await globalState.loadingRun<void>(
      tag: LoadingTag.profiles,
      () async {
        final prepared = await futureFunction();
        if (prepared.content.isEmpty) {
          throw StateError('candidate profile rendered an empty configuration');
        }
        await putPreparedProfile(prepared.profile, prepared.content);
      },
      title: currentAppLocalizations.addProfile,
      showCoreUnavailableErrors: true,
    );
  }

  Future<void> addOppaProfile(OppaProxyConfig config) async {
    await _addPreparedProfile(
      futureFunction: () => Profile.normal(label: config.name).prepareFile(
        Uint8List.fromList(utf8.encode(config.toYaml())),
        prepare: prepareProfileConfig,
      ),
    );
  }

  Future<void> addProfileFromDroppedFile({
    required String name,
    required Uint8List bytes,
  }) async {
    globalState.navigatorKey.currentState?.popUntil((route) => route.isFirst);
    ref.read(currentPageLabelProvider.notifier).toProfiles();
    await _addPreparedProfile(
      futureFunction: () => Profile.normal(
        label: name,
      ).prepareFile(bytes, prepare: prepareProfileConfig),
    );
  }

  Future<void> addProfileFormFile() async {
    final platformFile = await globalState.safeRun(picker.pickerFile);
    if (platformFile == null) return;
    await addProfileFromDroppedFile(
      name: platformFile.name,
      bytes: await platformFile.readBytes(),
    );
  }

  Future<void> addProfileFormURL(String url, {String? ageSecretKey}) async {
    if (globalState.navigatorKey.currentState?.canPop() ?? false) {
      globalState.navigatorKey.currentState?.popUntil((route) => route.isFirst);
    }
    ref.read(currentPageLabelProvider.notifier).value = PageLabel.profiles;
    await _addPreparedProfile(
      futureFunction: () => Profile.normal(
        url: url,
        ageSecretKey: ageSecretKey,
      ).prepareUpdate(prepare: prepareProfileConfig),
    );
  }

  void setProfileAndAutoApply(Profile profile) {
    ref.read(profilesProvider.notifier).put(profile);
    if (profile.id == ref.read(currentProfileIdProvider)) {
      ref.read(setupActionProvider.notifier).applyProfileDebounce();
    }
  }

  Future<void> addProfileFormQrCode() async {
    final url = await globalState.safeRun(picker.pickerConfigQRCode);
    if (url == null) return;
    unawaited(addProfileFormURL(url));
  }

  void reorder(List<Profile> profiles) {
    ref.read(profilesProvider.notifier).reorder(profiles);
  }

  Future<void> clearProviderEffect(int profileId) async {
    final error = await _core.deleteManagedPath(
      DeleteManagedPathParams(
        scope: ManagedPathScope.providers,
        relativePath: profileId.toString(),
      ),
    );
    if (error.isNotEmpty) {
      throw MessageException(error);
    }
  }

  Future<void> clearEffect(int profileId) async {
    final profilePath = await appPath.getProfilePath(profileId.toString());
    final profileFile = File(profilePath);
    final isExists = await profileFile.exists();
    if (isExists) {
      await profileFile.safeDelete(recursive: true);
    }
    await clearProviderEffect(profileId);
  }
}
