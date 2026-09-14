part of '../action.dart';

enum _SetupTaskResult { completed, handoffToCoreRestart, failed }

class _RunRequest {
  final bool running;
  final bool initialize;
  final DateTime? previousStartTime;

  const _RunRequest({
    required this.running,
    required this.initialize,
    required this.previousStartTime,
  });
}

@Riverpod(keepAlive: true)
class SetupAction extends _$SetupAction {
  static const _updateTickerTag = 'SetupAction.update';

  CoreController get _core => ref.read(coreHandlerProvider);

  final _setupScheduler = SerialTaskScheduler();
  final _listenerScheduler = SerialTaskScheduler();
  _RunRequest? _latestRunRequest;
  DateTime? _startTime;
  int _profileSwitchGeneration = 0;
  final ActivationEpochOwnership _activationOwnership =
      ActivationEpochOwnership();

  int beginProfileSwitch() => ++_profileSwitchGeneration;

  bool get _isRunning => _startTime != null && _startTime!.isBeforeNow;

  @override
  void build() {
    ref.onDispose(() => foregroundTicker.unregister(_updateTickerTag));
  }

  SetupParams get _setupParams {
    final selectedMap = ref.read(selectedMapProvider);
    final testUrl = ref.read(
      appSettingProvider.select((state) => state.testUrl),
    );
    return SetupParams(selectedMap: selectedMap, testUrl: testUrl);
  }

  ProfileSwitchPhaseTimer? _profileSwitchTimer(int generation, bool enabled) {
    if (!enabled) return null;
    return ProfileSwitchPhaseTimer(
      label: '${system.isAndroid ? 'android' : 'ios'}.profile_switch.$generation',
      sink: (phase, phaseElapsed, totalElapsed) {
        commonPrint.log(
          'timing $phase phase_ms=${phaseElapsed.inMilliseconds} '
          'total_ms=${totalElapsed.inMilliseconds}',
        );
      },
    );
  }

  Future<bool> fullSetup({
    bool profileSwitched = false,
    int? profileSwitchGeneration,
  }) async {
    if (!ref.read(initProvider)) return true;
    final generation =
        profileSwitchGeneration ??
        (profileSwitched ? beginProfileSwitch() : _profileSwitchGeneration);
    final ownsProfileSelection = profileSwitchGeneration != null;
    final activationEpoch = _activationOwnership.begin();
    final expectedProfileId = ref.read(currentProfileProvider)?.id;
    bool activationIsCurrent() =>
        _activationOwnership.isLatest(activationEpoch) &&
        (!ownsProfileSelection || generation == _profileSwitchGeneration);
    final timing = _profileSwitchTimer(generation, profileSwitched);
    final barrierToken = '${generation}_${DateTime.now().microsecondsSinceEpoch}';
    var barrierHeld = false;
    var setupSucceeded = false;
    var barrierResumed = true;
    try {
      if (profileSwitched) {
        barrierHeld = system.isIOS
            ? await Service().setProfileSwitchProbeBarrier(
                token: barrierToken,
                suspended: true,
              )
            : await _core.setProfileSwitchProbeBarrier(
                token: barrierToken,
                suspended: true,
              );
        timing?.mark('barrier_acquire');
        if (!barrierHeld || generation != _profileSwitchGeneration) {
          return false;
        }
      }
      await ref
          .read(proxiesActionProvider.notifier)
          .cancelDelayTests(cancelCoreRequests: profileSwitched);
      timing?.mark('delay_cancel');
      if (generation != _profileSwitchGeneration) return false;
      ref.read(delayDataSourceProvider.notifier).value = {};
      final setupResult = applyProfile(
        force: true,
        silence: profileSwitched,
        profileSwitched: profileSwitched,
        // A validation-only import intentionally has no generation yet. Every
        // explicit profile selection may fill that one missing generation;
        // the controller always consults the local committed index first, so
        // later A/B/A switches remain offline and reuse it.
        allowRuleGenerationPreparation: true,
        activationGuard: activationIsCurrent,
        timing: timing,
      );
      ref.read(logsProvider.notifier).value = FixedList(maxLogsLength);
      ref.read(requestsProvider.notifier).value = FixedList(maxRequestsLength);
      setupSucceeded = await setupResult;
      timing?.mark('setup');
      if (setupSucceeded && _activationOwnership.activate(activationEpoch)) {
        timing?.mark('activation_owned');
      } else {
        setupSucceeded = false;
      }
    } catch (e, s) {
      commonPrint.log('fullSetup ===> ${compactError(e)}, $s');
      return false;
    } finally {
      if (barrierHeld) {
        final resumed = system.isIOS
            ? await Service().setProfileSwitchProbeBarrier(
                token: barrierToken,
                suspended: false,
              )
            : await _core.setProfileSwitchProbeBarrier(
                token: barrierToken,
                suspended: false,
              );
        timing?.mark('barrier_resume');
        if (!resumed && generation == _profileSwitchGeneration) {
          commonPrint.log('failed to resume profile-switch probe barrier');
          barrierResumed = false;
        }
      }
    }
    if (profileSwitched && setupSucceeded && barrierResumed) {
      unawaited(
        _publishActivatedRuntimeState(
          epoch: activationEpoch,
          profileId: expectedProfileId,
          timing: timing,
        ),
      );
    }
    return setupSucceeded && barrierResumed;
  }

  Future<void> _publishActivatedRuntimeState({
    required int epoch,
    required int? profileId,
    ProfileSwitchPhaseTimer? timing,
  }) async {
    bool ownsActivation() => _activationOwnership.owns(epoch);
    try {
      final proxiesData = await _core.getProxiesData();
      final selectedMap = ref.read(
        currentProfileProvider.select((state) => state?.selectedMap ?? {}),
      );
      final groups = await computeGroups(
        proxiesData: proxiesData,
        selectedMap: selectedMap,
        sortType: ref.read(
          proxiesStyleSettingProvider.select((state) => state.sortType),
        ),
        delayMap: ref.read(delayDataSourceProvider),
        defaultTestUrl: ref.read(
          appSettingProvider.select((state) => state.testUrl),
        ),
      );
      timing?.mark('groups_sync');
      if (!ownsActivation() ||
          ref.read(currentProfileProvider)?.id != profileId) {
        return;
      }
      final providers = await _core.getExternalProviders();
      timing?.mark('providers_sync');
      _activationOwnership.publishIfOwned(epoch, () {
        if (ref.read(currentProfileProvider)?.id != profileId) return;
        ref.read(groupsProvider.notifier).value = groups;
        ref.read(providersProvider.notifier).value = providers;
      });
    } catch (e, s) {
      commonPrint.log('post-activation sync failed: ${compactError(e)}, $s');
    } finally {
      timing?.mark('post_activation_sync_done');
    }
  }

  void _setLocalRunning(bool running) {
    foregroundTicker.unregister(_updateTickerTag);
    if (!running) {
      _startTime = null;
      debouncer.cancel(FunctionTag.applyProfile);
      _updateRunTime();
      return;
    }

    _startTime ??= DateTime.now();
    _refreshRunningState();
    foregroundTicker.register(_updateTickerTag, _refreshRunningState);
  }

  void _refreshRunningState() {
    _updateRunTime();
    unawaited(ref.read(commonActionProvider.notifier).updateTraffic());
  }

  void _updateRunTime() {
    final startTime = _startTime;
    ref.read(runTimeProvider.notifier).value = startTime == null
        ? null
        : DateTime.now().millisecondsSinceEpoch -
              startTime.millisecondsSinceEpoch;
  }

  Future<void> _updateStartTime() async {
    _startTime = await readServiceRunTime();
  }

  @protected
  bool get shouldRestoreServiceRunTime => system.isMobile;

  @protected
  Future<DateTime?> readServiceRunTime() async => service?.getRunTime();

  Future<void> initStatus() async {
    if (!globalState.needInitStatus) {
      commonPrint.log('init status cancel');
      return;
    }
    commonPrint.log('init status');
    if (shouldRestoreServiceRunTime) {
      await _updateStartTime();
    }
    final shouldRun = _isRunning || ref.read(appSettingProvider).autoRun;
    if (shouldRun) {
      await setRunning(true, initialize: true);
    } else {
      await globalState.safeRun(() => applyProfile(force: true));
    }
  }

  Future<bool> setRunning(bool running, {bool initialize = false}) {
    if (running && !initialize && !ref.read(initProvider)) {
      return Future.value(true);
    }

    final request = _RunRequest(
      running: running,
      initialize: running && initialize,
      previousStartTime: _startTime,
    );
    _latestRunRequest = request;
    _setLocalRunning(running);
    if (request.initialize) {
      globalState.needInitStatus = false;
    }
    return running ? _start(request) : _stop(request);
  }

  Future<bool> _start(_RunRequest request) async {
    if (request.initialize) {
      var applied = false;
      try {
        applied = await applyProfile(
          force: true,
          activationGuard: () =>
              _isCurrent(request) && !ref.read(suspendProvider),
          preloadInvoke: () => _setCoreRunning(request),
        );
      } catch (_) {
        applied = false;
      }
      if (!applied && _isCurrent(request)) {
        await globalState.safeRun(() => setRunning(false));
      }
      return applied;
    }

    try {
      await _setCoreRunning(request);
    } catch (_) {
      _rollbackRunning(request);
      rethrow;
    }
    if (_isCurrent(request)) {
      applyProfileDebounce(force: true, silence: true);
    }
    return true;
  }

  Future<bool> _stop(_RunRequest request) async {
    try {
      await _setCoreRunning(request);
    } catch (_) {
      _rollbackRunning(request);
      rethrow;
    }
    if (!_isCurrent(request)) {
      return true;
    }
    if (system.isIOS) {
      globalState.lastConfigMd5 = null;
      await preferences.setAppliedConfigMd5(null);
    }
    resetCoreTraffic();
    ref.read(trafficsProvider.notifier).clear();
    ref.read(totalTrafficProvider.notifier).value = const Traffic();
    ref.read(checkIpNumProvider.notifier).add();
    return true;
  }

  Future<void> _setCoreRunning(_RunRequest request) {
    return _listenerScheduler.run(() async {
      if (!_isCurrent(request)) {
        return;
      }
      if (request.running && ref.read(suspendProvider)) {
        return;
      }
      await setCoreRunning(request.running);
    });
  }

  void _rollbackRunning(_RunRequest request) {
    if (!_isCurrent(request)) {
      return;
    }
    _startTime = request.previousStartTime;
    _setLocalRunning(!request.running);
  }

  bool _isCurrent(_RunRequest request) => identical(_latestRunRequest, request);

  Future<void> updateConfigDebounce() async {
    debouncer.call(FunctionTag.updateConfig, updateConfig);
  }

  @protected
  Future<bool> setCoreRunning(bool running) {
    return running ? _core.startListener() : _core.stopListener();
  }

  @protected
  void resetCoreTraffic() {
    _core.resetTraffic();
  }

  @visibleForTesting
  Future<void> updateConfig() async {
    await globalState.safeRun(() async {
      final updateParams = ref.read(updateParamsProvider);
      final shouldContinueSetup = await requestAdmin(updateParams.tun.enable);
      if (!shouldContinueSetup) {
        await _restartCoreAfterAuthorization();
        return;
      }
      final message = await _core.updateConfig(
        updateParams.copyWith.tun(
          enable: _getEffectiveTunEnable(updateParams.tun.enable),
        ),
      );
      ref.read(checkIpNumProvider.notifier).add();
      if (message.isNotEmpty) throw MessageException(message);
    });
  }

  void tryCheckIp() {
    final isTimeout = ref.read(
      networkDetectionProvider.select(
        (state) => state.ipInfo == null && state.isLoading == false,
      ),
    );
    if (!isTimeout) return;
    ref.read(checkIpNumProvider.notifier).add();
  }

  void applyProfileDebounce({bool silence = false, bool force = false}) {
    debouncer.call(FunctionTag.applyProfile, (silence, force) {
      applyProfile(silence: silence, force: force);
    }, args: [silence, force]);
  }

  void changeMode(Mode mode) {
    ref
        .read(patchClashConfigProvider.notifier)
        .update((state) => state.copyWith(mode: mode));
    if (mode == Mode.global) {
      ref
          .read(proxiesActionProvider.notifier)
          .updateCurrentGroupName(GroupName.GLOBAL.name);
    }
  }

  void autoApplyProfile() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      applyProfile();
    });
  }

  @protected
  bool get rulePrewarmEnabled => true;

  /// Prepares external rule-provider artifacts without activating the profile.
  Future<RuleGenerationPreparation?> prewarmProfile(
    Profile profile, {
    String? candidateYaml,
    bool allowUncommittedProfile = false,
  }) async {
    if (!rulePrewarmEnabled) {
      return null;
    }
    final knownProfile = ref.read(profileProvider(profile.id));
    if (knownProfile == null && !allowUncommittedProfile) {
      throw StateError('profile ${profile.id} is not committed');
    }
    final baseSetupState = await ref.read(
      setupStateProvider(knownProfile == null ? null : profile.id).future,
    );
    final setupState = baseSetupState.copyWith(
      profileId: profile.id,
      profileLastUpdateDate: profile.lastUpdateDate?.millisecondsSinceEpoch,
      overwriteType: profile.overwriteType,
      matchTarget: profile.matchTarget,
    );
    final patchConfig = ref.read(patchClashConfigProvider);
    final candidateRawConfig = candidateYaml == null
        ? null
        : await _core.parseProfileConfigData(candidateYaml);
    final rendered = await getProfile(
      setupState: setupState,
      patchConfig: patchConfig,
      candidateRawConfig: candidateRawConfig,
    );
    if (rendered.yaml.isEmpty) {
      throw StateError('candidate profile rendered an empty configuration');
    }
    final parsed = loadYaml(rendered.yaml);
    final ruleProviders = parsed is YamlMap ? parsed['rule-providers'] : null;
    final proxyProviders = parsed is YamlMap ? parsed['proxy-providers'] : null;
    bool hasExternalProvider(Object? providers) =>
        providers is YamlMap &&
        providers.values.any(
          (value) => value is YamlMap && value['type'] != 'inline',
        );
    final requiresPreparation =
        hasExternalProvider(ruleProviders) ||
        hasExternalProvider(proxyProviders);
    if (!requiresPreparation) {
      return null;
    }
    RulePreparationProgress? lastProgress;
    try {
      final preparation = await _core.prepareRuleGeneration(
        config: rendered.yaml,
        profileId: profile.id,
        onProgress: (progress) {
          lastProgress = progress;
          ref
              .read(rulePreparationProgressProvider.notifier)
              .update(progress);
        },
      );
      return preparation;
    } finally {
      final progress = lastProgress;
      if (progress != null) {
        ref
            .read(rulePreparationProgressProvider.notifier)
            .clear(key: progress.key);
      }
    }
  }

  // False means building the profile, the config write, or the Core setup
  // step failed; a profile that fails to build is still pushed to the Core
  // as the empty config so it never keeps serving the previous one.
  // authorizeCore failures still throw.
  Future<bool> applyProfile({
    bool silence = false,
    bool force = false,
    bool profileSwitched = false,
    bool allowRuleGenerationPreparation = false,
    bool Function()? activationGuard,
    Future<void> Function()? preloadInvoke,
    ProfileSwitchPhaseTimer? timing,
  }) async {
    final result = await _runSetup(
      force: force,
      silence: silence,
      profileSwitched: profileSwitched,
      allowRuleGenerationPreparation: allowRuleGenerationPreparation,
      activationGuard: activationGuard,
      preloadInvoke: preloadInvoke,
      timing: timing,
    );
    return result != _SetupTaskResult.failed;
  }

  Future<_SetupTaskResult> _runSetup({
    bool silence = false,
    bool force = false,
    bool profileSwitched = false,
    bool allowRuleGenerationPreparation = false,
    bool Function()? activationGuard,
    Future<void> Function()? preloadInvoke,
    ProfileSwitchPhaseTimer? timing,
  }) async {
    final expectedProfile = ref.read(currentProfileProvider);
    final expectedProfileId = expectedProfile?.id;
    final profileAction = ref.read(profilesActionProvider.notifier);
    if (expectedProfile != null) {
      await profileAction.ensureProfileFile(expectedProfile);
    }
    timing?.mark('profile_file');
    Future<_SetupTaskResult> runSetup() => _setupScheduler.run(() {
      if (activationGuard != null && !activationGuard()) {
        commonPrint.log('dropping stale setup before execution');
        return Future.value(_SetupTaskResult.failed);
      }
      return _setupConfig(
        expectedProfileId: expectedProfileId,
        force: force,
        silence: silence,
        profileSwitched: profileSwitched,
        allowRuleGenerationPreparation: allowRuleGenerationPreparation,
        activationGuard: activationGuard,
        preloadInvoke: preloadInvoke,
        timing: timing,
        onUpdated: profileSwitched
            ? null
            : () async {
                if (activationGuard != null && !activationGuard()) return;
                await ref
                    .read(proxiesActionProvider.notifier)
                    .updateGroups(profileId: expectedProfileId);
                timing?.mark('groups_sync');
                if (activationGuard != null && !activationGuard()) return;
                await ref
                    .read(providersProvider.notifier)
                    .syncProviders(profileId: expectedProfileId);
                timing?.mark('providers_sync');
              },
      );
    });
    final result = expectedProfileId == null
        ? await runSetup()
        : await profileAction.withProfileTransaction(
            expectedProfileId,
            runSetup,
          );
    if (result != _SetupTaskResult.handoffToCoreRestart) {
      return result;
    }
    // Release the current serial task before restartCore reapplies the profile.
    final restarted = await _restartCoreAfterAuthorization();
    return restarted ? _SetupTaskResult.completed : _SetupTaskResult.failed;
  }

  Future<bool> _restartCoreAfterAuthorization() async {
    try {
      return await ref.read(coreActionProvider.notifier).restartCore();
    } catch (_) {
      ref.read(authorizedTunEnableProvider.notifier).value =
          TunAuthorizationState.none;
      rethrow;
    }
  }

  Future<({String yaml, String md5})> getProfile({
    required SetupState setupState,
    required PatchClashConfig patchConfig,
    Map<String, dynamic>? candidateRawConfig,
  }) async {
    final profileId = setupState.profileId;
    if (profileId == null) return (yaml: '', md5: '');
    final defaultUA = globalState.packageInfo.ua;
    final networkSetting = ref.read(
      networkSettingProvider.select(
        (state) => (
          appendSystemDns: state.appendSystemDns,
          routeMode: state.routeMode,
          authentication: state.authentication,
        ),
      ),
    );
    final overrideDns = ref.read(overrideDnsProvider);
    final appendSystemDns = networkSetting.appendSystemDns;
    final routeMode = networkSetting.routeMode;
    final configMap =
        candidateRawConfig ?? await _core.getConfig(profileId);
    String? scriptContent;
    final List<Rule> addedRules = [];
    final List<ProxyGroup> proxyGroups = [];
    final List<Rule> rules = [];
    if (setupState.overwriteType == OverwriteType.script) {
      scriptContent = await setupState.script?.content;
    } else if (setupState.overwriteType == OverwriteType.standard) {
      addedRules.addAll(setupState.addedRules);
    } else {
      proxyGroups.addAll(setupState.proxyGroups);
      rules.addAll(setupState.rules);
    }
    final realPatchConfig = patchConfig.copyWith(
      tun: patchConfig.tun.getRealTun(routeMode),
    );
    Map<String, dynamic> rawConfig = configMap;
    if (scriptContent?.isNotEmpty == true) {
      rawConfig = await handleEvaluate(scriptContent!, rawConfig);
    }
    final directory = await appPath.profilesPath;
    final res = makeRealProfileTask(
      MakeRealProfileState(
        rules: rules,
        proxyGroups: proxyGroups,
        profilesPath: directory,
        profileId: profileId,
        rawConfig: rawConfig,
        realPatchConfig: realPatchConfig,
        overrideDns: overrideDns,
        appendSystemDns: appendSystemDns,
        addedRules: addedRules,
        defaultUA: defaultUA,
        authentication: networkSetting.authentication.credentials,
        matchTarget: setupState.matchTarget,
      ),
    );
    return res;
  }

  Future<String> getProfileWithId(int profileId) async {
    try {
      final setupState = await ref.read(setupStateProvider(profileId).future);
      final patchClashConfig = ref.read(patchClashConfigProvider);
      final res = await getProfile(
        setupState: setupState,
        patchConfig: patchClashConfig,
      );
      return res.yaml;
    } catch (e) {
      dialogs.showNotifier(e.toString(), level: MessageLevel.error);
    }
    return '';
  }

  bool _getEffectiveTunEnable(bool enableTun) {
    final authorizationState = ref.read(authorizedTunEnableProvider);
    return enableTun && authorizationState == TunAuthorizationState.authorized;
  }

  @protected
  Future<AuthorizeCode> authorizeCore() {
    return system.authorizeCore();
  }

  @visibleForTesting
  Future<bool> requestAdmin(bool enableTun) async {
    if (!enableTun) {
      return true;
    }
    final authorizationState = ref.read(authorizedTunEnableProvider);
    if (authorizationState != TunAuthorizationState.none) {
      return true;
    }

    final authorizationNotifier = ref.read(
      authorizedTunEnableProvider.notifier,
    );
    authorizationNotifier.value = TunAuthorizationState.unauthorized;

    final code = await authorizeCore();

    switch (code) {
      case AuthorizeCode.success:
        authorizationNotifier.value = TunAuthorizationState.authorized;
        return false;
      case AuthorizeCode.none:
        authorizationNotifier.value = TunAuthorizationState.authorized;
        return true;
      case AuthorizeCode.error:
        return true;
    }
  }

  /// An empty profile list is left alone: it is the first-run state, and it is
  /// what the profile stream holds before its first emission.
  @visibleForTesting
  Profile? recoverMissingProfile() {
    final profileId = ref.read(currentProfileIdProvider);
    if (profileId == null) return null;
    final profiles = ref.read(profilesProvider);
    if (profiles.isEmpty) return null;
    final fallback = profiles.first;
    commonPrint.log(
      'profile $profileId is missing, falling back to ${fallback.id}',
      logLevel: LogLevel.warning,
    );
    ref.read(currentProfileIdProvider.notifier).value = fallback.id;
    return fallback;
  }

  Future<bool> _persistConfigAtomicallyIfCurrent(
    String path,
    String config, {
    bool Function()? commitGuard,
  }) async {
    final target = File(path);
    await target.parent.create(recursive: true);
    final temporary = File(
      '$path.tmp.$pid.${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await temporary.writeAsString(config, flush: true);
      if (commitGuard != null && !commitGuard()) return false;
      await temporary.rename(path);
      return true;
    } finally {
      await temporary.safeDelete();
    }
  }

  Future<_SetupTaskResult> _setupConfig({
    required int? expectedProfileId,
    bool force = false,
    bool silence = false,
    bool profileSwitched = false,
    bool allowRuleGenerationPreparation = false,
    bool Function()? activationGuard,
    Future<void> Function()? preloadInvoke,
    ProfileSwitchPhaseTimer? timing,
    FutureOr Function()? onUpdated,
  }) async {
    final profile = expectedProfileId == null
        ? recoverMissingProfile()
        : ref.read(profilesProvider).getProfile(expectedProfileId);
    commonPrint.log('setup ===> ${profile?.realLabel}');
    final patchConfig = ref.read(patchClashConfigProvider);
    final shouldContinueSetup = await requestAdmin(patchConfig.tun.enable);
    if (!shouldContinueSetup) {
      return _SetupTaskResult.handoffToCoreRestart;
    }
    final effectiveTunEnable = _getEffectiveTunEnable(patchConfig.tun.enable);
    final realPatchConfig = patchConfig.copyWith.tun(
      enable: effectiveTunEnable,
    );
    final realProfile = await globalState.safeRun(() async {
      final setupState = await ref.read(setupStateProvider(profile?.id).future);
      return getProfile(setupState: setupState, patchConfig: realPatchConfig);
    }, title: 'build profile');
    timing?.mark('render_config');
    final profileFailed = realProfile == null;
    final yamlString = realProfile?.yaml ?? '';
    final yamlMd5 = realProfile?.md5 ?? '';
    final appliedMd5 =
        globalState.lastConfigMd5 ?? await preferences.getAppliedConfigMd5();
    final configFile = File(await appPath.configFilePath);
    final diskMatches =
        await configFile.exists() &&
        (await configFile.readAsString()).toMd5() == yamlMd5;
    final matchesAppliedConfig =
        !profileFailed && yamlMd5 == appliedMd5 && diskMatches;
    final skipRedundantReload =
        !profileSwitched &&
        matchesAppliedConfig &&
        (!force || (system.isIOS && _isRunning));
    if (skipRedundantReload) {
      globalState.lastConfigMd5 = yamlMd5;
      await preloadInvoke?.call();
      await onUpdated?.call();
      return _SetupTaskResult.completed;
    }
    if (system.isAndroid) {
      globalState.lastVpnOptions = ref.read(vpnOptionsProvider);
      final sharedState = ref.read(sharedStateProvider);
      await preferences.saveShareState(sharedState);
    }
    // Recaptured so _start's catch can roll back after safeRun swallows it.
    (Object, StackTrace)? handoffFailure;
    var setupFailed = false;
    var setupStale = false;
    await globalState.loadingRun(
      () async {
        try {
          final configFilePath = await appPath.configFilePath;
          if (activationGuard != null && !activationGuard()) {
            commonPrint.log('dropping stale setup before config persistence');
            setupStale = true;
            return;
          }
          if (!system.isIOS) {
            final persisted = await _persistConfigAtomicallyIfCurrent(
              configFilePath,
              yamlString,
              commitGuard: activationGuard,
            );
            if (!persisted) {
              setupStale = true;
              return;
            }
          }
          timing?.mark('persist_config');
          if (activationGuard != null && !activationGuard()) {
            commonPrint.log('dropping stale setup before Core activation');
            setupStale = true;
            return;
          }
          final profileId = profile?.id;
          if (profileId != null) {
            await appPath.ensureProviderDirs(profileId);
          }
          final parsedSetupConfig = loadYaml(yamlString);
          bool hasExternalProvider(Object? providers) =>
              providers is YamlMap &&
              providers.values.any(
                (value) => value is YamlMap && value['type'] != 'inline',
              );
          final requiresCommittedGeneration =
              parsedSetupConfig is YamlMap &&
              (hasExternalProvider(parsedSetupConfig['rule-providers']) ||
                  hasExternalProvider(parsedSetupConfig['proxy-providers']));
          if (activationGuard != null && !activationGuard()) {
            commonPrint.log('dropping stale setup after provider directory preparation');
            setupStale = true;
            return;
          }
          final coreController = _core;
          Future<void> commitAndActivate() async {
            // _start marks local state running before initialization. A supplied
            // activation guard owns stale-request and suspend arbitration.
            if (activationGuard != null && !activationGuard()) {
              throw StateError('iOS activation request is no longer current');
            }
            final onlineSwitch = _isRunning && preloadInvoke == null;
            Future<String> applyFormalConfig() {
              return coreController.applyFormalConfig(_setupParams);
            }

            if (onlineSwitch) {
              await commitAndHotApplyIOSConfig(
                configPath: configFilePath,
                config: yamlString,
                activationGuard: activationGuard,
                persistAtomically: (path, config) async {
                  final persisted = await _persistConfigAtomicallyIfCurrent(
                    path,
                    config,
                  );
                  if (!persisted) {
                    throw StateError('iOS config persistence was rejected');
                  }
                },
                applyConfig: applyFormalConfig,
                restoreConfig: applyFormalConfig,
              );
              return;
            }
            await commitAndActivateIOSConfig(
              configPath: configFilePath,
              config: yamlString,
              oldTunnelWasRunning: false,
              activationGuard: activationGuard,
              persistAtomically: (path, config) async {
                final persisted = await _persistConfigAtomicallyIfCurrent(
                  path,
                  config,
                );
                if (!persisted) {
                  throw StateError('iOS config persistence was rejected');
                }
              },
              stopTunnel: () => setCoreRunning(false),
              restoreTunnel: () async {
                final restoreResult = await applyFormalConfig();
                if (restoreResult.isNotEmpty) {
                  throw MessageException(restoreResult);
                }
                return setCoreRunning(true);
              },
              startTunnel: () async {
                if (activationGuard != null && !activationGuard()) {
                  throw StateError(
                    'iOS activation request is no longer current',
                  );
                }
                final applyResult = await applyFormalConfig();
                if (applyResult.isNotEmpty) {
                  throw MessageException(applyResult);
                }
                if (preloadInvoke != null) {
                  // A stale or suspended initialization deliberately no-ops in
                  // _setCoreRunning; that is successful intent arbitration.
                  await preloadInvoke();
                  return true;
                }
                if (!onlineSwitch) {
                  return true;
                }
                return setCoreRunning(true);
              },
            );
          }

          final message = await coreController.setupConfig(
            params: _setupParams,
            preparationConfig: requiresCommittedGeneration ? yamlString : null,
            preparationProfileId: requiresCommittedGeneration ? profileId : null,
            allowRuleGenerationPreparation: allowRuleGenerationPreparation,
            preloadInvoke: system.isIOS ? commitAndActivate : preloadInvoke,
            timing: timing,
          );
          if (message.isNotEmpty) {
            throw MessageException(message);
          }
        } catch (e, s) {
          setupFailed = true;
          if (preloadInvoke != null) {
            handoffFailure = (e, s);
          }
          rethrow;
        }
        final appliedYamlMd5 = (await configFile.readAsString()).toMd5();
        globalState.lastConfigMd5 = appliedYamlMd5;
        await preferences.setAppliedConfigMd5(appliedYamlMd5);
        ref.read(checkIpNumProvider.notifier).add();
        await onUpdated?.call();
      },
      silence: true,
      tag: !silence ? LoadingTag.proxies : null,
    );
    if (handoffFailure != null) {
      Error.throwWithStackTrace(handoffFailure!.$1, handoffFailure!.$2);
    }
    if (setupFailed || setupStale || profileFailed) {
      return _SetupTaskResult.failed;
    }
    return _SetupTaskResult.completed;
  }
}
