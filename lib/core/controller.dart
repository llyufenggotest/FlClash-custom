import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/core/rule_generation_preparer.dart';
import 'package:fl_clash/core/rule_preparation_scheduler.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:path/path.dart';

class CoreController {
  static CoreController? _instance;
  late CoreHandlerInterface _interface;

  CoreController._internal() {
    if (system.isMobile) {
      _interface = coreLib!;
    } else {
      _interface = coreService!;
    }
  }

  @visibleForTesting
  CoreController.test(this._interface) {
    _instance = this;
  }

  @visibleForTesting
  CoreController.scoped(this._interface);

  @visibleForTesting
  static void resetInstance() {
    _instance = null;
  }

  factory CoreController() {
    _instance ??= CoreController._internal();
    return _instance!;
  }

  Future<CoreLifecycleResult> start() => _interface.start();

  Future<CoreLifecycleResult> restart() => _interface.restart();

  Future<CoreLifecycleResult> stop() => _interface.stop();

  Future<CoreLifecycleResult> close() => _interface.close();

  static Future<void> ensureHomeDir() async {
    final homePath = await appPath.homeDirPath;
    final homeDir = Directory(homePath);
    final isExists = await homeDir.exists();
    if (!isExists) {
      await homeDir.create(recursive: true);
    }
    await system.grantHomeDirAccess(homePath);
  }

  static Future<void> initGeo() async {
    final homePath = await appPath.homeDirPath;
    const geoFileNameList = [MMDB, GEOIP, GEOSITE, ASN, BUNDLE_MRS];
    try {
      for (final geoFileName in geoFileNameList) {
        final geoFile = File(join(homePath, geoFileName));
        final isExists = await geoFile.exists();
        if (isExists) {
          continue;
        }
        final data = await rootBundle.load('assets/data/$geoFileName');
        final List<int> bytes = data.buffer.asUint8List();
        await geoFile.writeAsBytes(bytes, flush: true);
      }
    } catch (e) {
      commonPrint.log(
        'Failed to initialize geo data: $e',
        logLevel: LogLevel.error,
      );
      rethrow;
    }
  }

  Future<bool> init(int version) async {
    await ensureHomeDir();
    await initGeo();
    final homeDirPath = await appPath.homeDirPath;
    return _interface.init(InitParams(homeDir: homeDirPath, version: version));
  }

  FutureOr<bool> get isInit => _interface.isInit;

  Future<String> validateConfig(String data) async {
    final res = await _interface.validateConfig(data);
    return res;
  }

  Future<String> validateConfigWithData(String data) async {
    return validateConfig(data);
  }

  Future<String> decryptAgeConfig(String data, String ageSecretKey) {
    return _interface.decryptAgeConfig(data, ageSecretKey);
  }

  Future<String> updateConfig(UpdateParams updateParams) async {
    return _interface.updateConfig(updateParams);
  }

  Future<String> applyFormalConfig(SetupParams params) {
    return _interface.setupConfig(params);
  }

  Future<RuleGenerationPreparation> prepareRuleGeneration({
    required String config,
    required int profileId,
  }) {
    return RuleGenerationPreparer(
      core: _interface,
    ).prepare(profileId: profileId, config: config);
  }

  Future<RuleGenerationPreparation?> getPreparedRuleGeneration({
    required String config,
    required int profileId,
  }) {
    return RuleGenerationPreparer(
      core: _interface,
    ).findPrepared(profileId: profileId, config: config);
  }

  Future<String> setupConfig({
    required SetupParams params,
    Future<void> Function()? preloadInvoke,
    Future<void> Function(String preparedConfig)? persistPreparedConfig,
    String? preparationConfig,
    int? preparationProfileId,
    @visibleForTesting
    Future<RuleGenerationPreparation> Function({
      required String config,
      required int profileId,
    })?
    prepareRuleGenerationOverride,
    @visibleForTesting bool? prepareBeforePreload,
    @visibleForTesting
    Duration rulePreparationTimeout = const Duration(seconds: 60),
  }) async {
    final prepareFirst = prepareBeforePreload ?? system.isIOS;
    String? candidateConfigPath;
    Future<String> preparation() async {
      final config = preparationConfig;
      final profileId = preparationProfileId;
      if (prepareFirst && config != null && profileId != null) {
        try {
          final fingerprint = sha256.convert(utf8.encode(config)).toString();
          final prepareOperation =
              prepareRuleGenerationOverride ?? prepareRuleGeneration;
          final prepared = await preparedGenerationScheduler.prepare(
            jsonEncode({'profile-id': profileId, 'fingerprint': fingerprint}),
            () => prepareOperation(config: config, profileId: profileId),
          );
          // This assignment runs in every waiter, including a connect that
          // joined an import-time prewarm already in flight.
          candidateConfigPath = prepared.configPath;
          await persistPreparedConfig?.call(prepared.config);
          return '';
        } on Object catch (error) {
          return error.toString();
        }
      }
      return _interface.setupConfig(params);
    }

    Future<String> prepare() {
      final config = preparationConfig;
      final profileId = preparationProfileId;
      if (config == null || profileId == null || prepareFirst) {
        return preparation();
      }
      final fingerprint = sha256.convert(utf8.encode(config)).toString();
      return rulePreparationScheduler.prepare(
        jsonEncode({'profile-id': profileId, 'fingerprint': fingerprint}),
        preparation,
      );
    }

    if (!prepareFirst) {
      if (preloadInvoke == null) {
        return preparation();
      }
      final (result, _) = await (preparation(), preloadInvoke()).wait;
      return result;
    }

    final isolatedPreparation =
        prepareFirst &&
        preparationConfig != null &&
        preparationProfileId != null;
    // Every iOS waiter is bounded, including a background call without a
    // preload callback. A connect can still reuse the same in-flight future.
    final timeoutLabel = rulePreparationTimeout.inMilliseconds % 1000 == 0
        ? '${rulePreparationTimeout.inSeconds}s'
        : '${rulePreparationTimeout.inMilliseconds}ms';
    var result = await prepare().timeout(
      rulePreparationTimeout,
      onTimeout: () =>
          'iOS rule preparation timed out after $timeoutLabel; '
          'network extension was not started',
    );
    if (result.isEmpty && isolatedPreparation && candidateConfigPath == null) {
      try {
        final prepared = await getPreparedRuleGeneration(
          config: preparationConfig,
          profileId: preparationProfileId,
        );
        if (prepared == null) {
          result = 'prepared config path is missing';
        } else {
          candidateConfigPath = prepared.configPath;
          await persistPreparedConfig?.call(prepared.config);
        }
      } on Object catch (error) {
        result = error.toString();
      }
    }
    if (result.isNotEmpty) {
      return result;
    }
    if (isolatedPreparation && preloadInvoke != null) {
      // The isolated stage only publishes immutable artifacts. Runner must
      // still admit the prepared config and publish the NE runtime readiness
      // manifest before the extension starts. This pass is local-only because
      // every HTTP provider now references the prepared generation.
      final path = candidateConfigPath;
      if (path == null || path.isEmpty) {
        result = 'prepared config path is missing';
      } else {
        result = await _interface.validateCandidateConfigAtPath(path);
      }
    }
    if (result.isNotEmpty) {
      return result;
    }
    await preloadInvoke?.call();
    return result;
  }

  Future<List<Group>> getProxiesGroups({
    required ProxiesSortType sortType,
    required DelayMap delayMap,
    required Map<String, String> selectedMap,
    required String defaultTestUrl,
  }) async {
    final proxiesData = await _interface.getProxies();
    return toGroupsTask(
      ComputeGroupsState(
        proxiesData: proxiesData,
        sortType: sortType,
        delayMap: delayMap,
        selectedMap: selectedMap,
        defaultTestUrl: defaultTestUrl,
      ),
    );
  }

  FutureOr<String> changeProxy(
    ChangeProxyParams changeProxyParams, {
    bool closeConnections = false,
  }) async {
    return await _interface.changeProxy(
      changeProxyParams,
      closeConnections: closeConnections,
    );
  }

  Future<List<TrackerInfo>> getConnections() async {
    return _interface.getConnections();
  }

  Future<void> closeConnection(String id) async {
    await _interface.closeConnection(id);
  }

  Future<void> closeConnections() async {
    await _interface.closeConnections();
  }

  Future<void> resetConnections() async {
    await _interface.resetConnections();
  }

  Future<List<ExternalProvider>> getExternalProviders() async {
    return _interface.getExternalProviders();
  }

  Future<ExternalProvider?> getExternalProvider(
    String externalProviderName,
  ) async {
    return _interface.getExternalProvider(externalProviderName);
  }

  Future<List<OverlayNetworkStatus>> getOverlayNetworkStatus(
    GetOverlayNetworkStatusParams params,
  ) async {
    return _interface.getOverlayNetworkStatus(params);
  }

  Future<OverlayNetworkStatus> activateOverlayNetwork(
    String name,
    OverlayNetworkKind kind,
  ) {
    return _interface.activateOverlayNetwork(name, kind);
  }

  Future<TailscalePingResult> pingTailscaleNode(String name, String ip) {
    return _interface.pingTailscaleNode(name, ip);
  }

  Future<bool> logoutTailscale(String name) {
    return _interface.logoutTailscale(name);
  }

  Future<String> updateGeoData(String type) {
    return _interface.updateGeoData(type);
  }

  Future<String> sideLoadExternalProvider({
    required String providerName,
    required String data,
  }) {
    return _interface.sideLoadExternalProvider(
      providerName: providerName,
      data: data,
    );
  }

  Future<String> updateExternalProvider({required String providerName}) async {
    return _interface.updateExternalProvider(providerName);
  }

  Future<bool> startListener() async {
    return _interface.startListener();
  }

  Future<bool> stopListener() async {
    return _interface.stopListener();
  }

  Future<Delay?> getDelay(String url, String proxyName) async {
    return _interface.asyncTestDelay(url, proxyName);
  }

  Future<Map<String, dynamic>> getConfig(int id) async {
    final data = Map<String, dynamic>.from(
      await _interface.getProfileConfig(id),
    );
    data['rules'] = data['rule'];
    data.remove('rule');
    return data;
  }

  Future<Traffic> getTraffic(bool onlyStatisticsProxy) async {
    return _interface.getTraffic(onlyStatisticsProxy);
  }

  Future<Traffic> getTotalTraffic(bool onlyStatisticsProxy) async {
    return _interface.getTotalTraffic(onlyStatisticsProxy);
  }

  Future<int> getMemory() async {
    return _interface.getMemory();
  }

  Future<int> getGoroutineCount() async {
    return _interface.getGoroutineCount();
  }

  void resetTraffic() {
    _interface.resetTraffic();
  }

  Future<List<Log>> startLogNotify() async {
    return _interface.startLogNotify();
  }

  void stopLogNotify() {
    _interface.stopLogNotify();
  }

  Future<List<TrackerInfo>> startRequestNotify() async {
    return _interface.startRequestNotify();
  }

  void stopRequestNotify() {
    _interface.stopRequestNotify();
  }

  Future<void> requestGc() async {
    await _interface.forceGc();
  }

  Future<void> crash() async {
    await _interface.crash();
  }

  Future<String> clearEffect(int profileId) async {
    return _interface.clearEffect(profileId);
  }

  Future<String> deleteManagedPath(DeleteManagedPathParams params) async {
    return _interface.deleteManagedPath(params);
  }

  Future<Map<String, String>> generateAgeKeyPair() {
    return _interface.generateAgeKeyPair();
  }

  Future<String> convertAgeSecretKeyToPublicKey(String secretKey) {
    return _interface.convertAgeSecretKeyToPublicKey(secretKey);
  }
}

final coreController = CoreController();
