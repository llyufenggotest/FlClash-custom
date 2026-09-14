part of '../action.dart';

@Riverpod(keepAlive: true)
class ProfilesAction extends _$ProfilesAction {
  CoreController get _core => ref.read(coreHandlerProvider);

  final Map<int, Future<void>> _selectionTransactionTails = {};
  final Map<int, Future<void>> _switchTransactionTails = {};

  Future<T> withProfileTransaction<T>(
    int profileId,
    Future<T> Function() action,
  ) async {
    final previous = _switchTransactionTails[profileId] ?? Future<void>.value();
    final completer = Completer<void>();
    _switchTransactionTails[profileId] = completer.future;
    try {
      await previous.catchError((_) {});
      return await action();
    } finally {
      completer.complete();
      if (identical(_switchTransactionTails[profileId], completer.future)) {
        unawaited(_switchTransactionTails.remove(profileId));
      }
    }
  }

  Future<void> ensureProfileFile(Profile profile) async {
    final path = await appPath.getProfilePath(profile.id.toString());
    if (await File(path).exists() || profile.url.isEmpty) return;
    await updateProfile(profile);
  }

  Future<void> _withSelectionTransaction(
    int profileId,
    Future<void> Function() action,
  ) async {
    final previous =
        _selectionTransactionTails[profileId] ?? Future<void>.value();
    final completer = Completer<void>();
    _selectionTransactionTails[profileId] = completer.future;
    try {
      await previous.catchError((_) {});
      await action();
    } finally {
      completer.complete();
      if (identical(_selectionTransactionTails[profileId], completer.future)) {
        unawaited(_selectionTransactionTails.remove(profileId));
      }
    }
  }

  @override
  void build() {}

  Future<void> updateCurrentSelectedMap(
    String groupName,
    String proxyName,
  ) async {
    final currentProfile = ref.read(currentProfileProvider);
    if (currentProfile == null) return;
    await _withSelectionTransaction(currentProfile.id, () async {
      final profile = ref.read(profilesProvider).getProfile(currentProfile.id);
      if (profile == null || profile.selectedMap[groupName] == proxyName) {
        return;
      }
      final selectedMap = Map<String, String>.from(profile.selectedMap);
      if (proxyName.isEmpty) {
        selectedMap.remove(groupName);
      } else {
        selectedMap[groupName] = proxyName;
      }
      await ref
          .read(profilesProvider.notifier)
          .putAsync(profile.copyWith(selectedMap: selectedMap));
    });
  }

  Future<void> deleteProfile(int id) async {
    await ref.read(profilesProvider.notifier).del(id);
    await clearEffect(id);
    final currentProfileId = ref.read(currentProfileIdProvider);
    if (currentProfileId == id) {
      final profiles = ref.read(profilesProvider);
      if (profiles.isNotEmpty) {
        ref.read(currentProfileIdProvider.notifier).value = profiles.first.id;
      } else {
        ref.read(currentProfileIdProvider.notifier).value = null;
        unawaited(ref.read(setupActionProvider.notifier).setRunning(false));
      }
    }
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
      if (decrypted.isNotEmpty) prepared = decrypted;
    }
    final message = await _core.validateConfig(prepared);
    if (message.isNotEmpty) throw MessageException(message);
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

  void putProfile(Profile profile) {
    ref.read(profilesProvider.notifier).put(profile);
    if (ref.read(currentProfileIdProvider) != null) return;
    ref.read(currentProfileIdProvider.notifier).value = profile.id;
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
    try {
      ref.read(profilesProvider.notifier).put(profile);
      final newProfile = await profile.update(prepare: prepareProfileConfig);
      ref.read(profilesProvider.notifier).put(newProfile);
      if (profile.id == ref.read(currentProfileIdProvider)) {
        ref
            .read(setupActionProvider.notifier)
            .applyProfileDebounce(silence: true);
      } else {
        unawaited(
          ref
              .read(setupActionProvider.notifier)
              .scheduleProfilePrewarm(newProfile),
        );
      }
    } finally {
      if (operation != null) {
        ref
            .read(updatingKeysProvider.notifier)
            .stop(profile.updatingKey, operation);
      }
    }
  }

  Future<void> _addSavedProfile({
    required Future<Profile> Function() futureFunction,
  }) async {
    final profile = await globalState.loadingRun(
      tag: LoadingTag.profiles,
      futureFunction,
      title: currentAppLocalizations.addProfile,
    );
    if (profile != null) {
      putProfile(profile);
      if (ref.read(currentProfileIdProvider) != profile.id) {
        unawaited(
          ref
              .read(setupActionProvider.notifier)
              .scheduleProfilePrewarm(profile),
        );
      }
    }
  }

  Future<void> addOppaProfile(OppaProxyConfig config) async {
    await _addSavedProfile(
      futureFunction: () => Profile.normal(label: config.name).saveFile(
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
    await _addSavedProfile(
      futureFunction: () => Profile.normal(
        label: name,
      ).saveFile(bytes, prepare: prepareProfileConfig),
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
    await _addSavedProfile(
      futureFunction: () => Profile.normal(
        url: url,
        ageSecretKey: ageSecretKey,
      ).update(prepare: prepareProfileConfig),
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

  Future<void> clearEffect(int profileId) async {
    final profilePath = await appPath.getProfilePath(profileId.toString());
    final profileFile = File(profilePath);
    if (await profileFile.exists()) {
      await profileFile.safeDelete(recursive: true);
    }
    final error = await _core.deleteManagedPath(
      DeleteManagedPathParams(
        scope: ManagedPathScope.providers,
        relativePath: profileId.toString(),
      ),
    );
    if (error.isNotEmpty) {
      commonPrint.log(error, logLevel: LogLevel.warning);
    }
  }
}
