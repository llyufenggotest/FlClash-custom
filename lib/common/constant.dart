// ignore_for_file: constant_identifier_names

import 'dart:math';
import 'dart:ui';

import 'package:collection/collection.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:flutter/material.dart';

const appName = 'FlClash';
const appHelperService = 'FlClashHelperService';
const coreManifestName = 'manifest.json';
const browserUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
const packageName = 'com.follow.clash';
final unixSocketPath = '/tmp/FlClashSocket_${Random().nextInt(10000)}.sock';
final windowsPipeName = '\\\\.\\pipe\\FlClashCore_${_randomPipeId()}';
const helperPort = 47890;
const helperProtocolVersionHeader = 'x-flclash-helper-protocol';
const helperProtocolVersion = '6';
const maxTextScale = 1.4;
const minTextScale = 0.8;
final baseInfoEdgeInsets = EdgeInsets.symmetric(
  vertical: 16.mAp,
  horizontal: 16.mAp,
);
final listHeaderPadding = EdgeInsets.only(
  left: 16.mAp,
  right: 8.mAp,
  top: 24.mAp,
  bottom: 8.mAp,
);
const sheetAppBarHeight = 68.0;

const watchExecution = false;

String _randomPipeId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

final defaultTextScaleFactor =
    WidgetsBinding.instance.platformDispatcher.textScaleFactor;
const httpTimeoutDuration = Duration(milliseconds: 5000);

/// Keep at or below the Core's delay-test concurrency (`mBatch` in
/// core/common.go). Surplus requests queue inside the Core behind a full wave
/// of 5s timeouts, which no RPC timeout can cover.
///
/// On iOS the Core lives in the Network Extension, which is built with
/// `with_low_memory` and therefore caps `delayBatchConcurrency` at 8
/// (core/memory_budget_ios_extension.go). Sending 50 from the app made 42
/// probes queue inside a process that dies at ~48 MB phys_footprint: the
/// 2026-08-29 22:46 traces show 56 provider messages issued in one second,
/// 65 in flight at the peak, footprint climbing 32 -> 47 MB in three seconds
/// and jetsam killing the extension on the next tick. Every one of the four
/// tunnel lives in those traces died that way.
const _maxConcurrentDelayTestsDefault = 50;

/// Mirrors `delayBatchConcurrency` in core/memory_budget_ios_extension.go.
/// These two numbers must move together.
const _maxConcurrentDelayTestsIOS = 8;

final maxConcurrentDelayTests = system.isIOS
    ? _maxConcurrentDelayTestsIOS
    : _maxConcurrentDelayTestsDefault;
const moreDuration = Duration(milliseconds: 100);
const animateDuration = Duration(milliseconds: 100);
const midDuration = Duration(milliseconds: 200);
const commonDuration = Duration(milliseconds: 300);
const defaultUpdateDuration = Duration(days: 1);
const MMDB = 'GeoIP.metadb';
const ASN = 'ASN.mmdb';
const GEOIP = 'GeoIP.dat';
const GEOSITE = 'GeoSite.dat';
const BUNDLE_MRS = 'BundleMRS.7z';
final double kHeaderHeight = system.isDesktop
    ? !system.isMacOS
          ? 40
          : 28
    : 0;
const profilesDirectoryName = 'profiles';
const localhost = '127.0.0.1';
const clashConfigKey = 'clash_config';
const configKey = 'config';

/// Survives app relaunches so a foreground return can tell whether the
/// long-lived core already runs the config the app is about to apply.
const appliedConfigMd5Key = 'applied_config_md5';
const double dialogCommonWidth = 300;
const repository = 'chenx-dust/FlClash-Patched';
const defaultExternalControllerPort = 9090;
const maxMobileWidth = 600;
const maxLaptopWidth = 840;
const defaultTestUrl = 'https://www.gstatic.com/generate_204';
const compatibleProxyName = 'COMPATIBLE';
final commonFilter = ImageFilter.blur(
  sigmaX: 5,
  sigmaY: 5,
  tileMode: TileMode.clamp,
);

const listEquality = ListEquality();
const navigationItemListEquality = ListEquality<NavigationItem>();
const trackerInfoListEquality = ListEquality<TrackerInfo>();
const stringListEquality = ListEquality<String>();
const intListEquality = ListEquality<int>();
const logListEquality = ListEquality<Log>();
const groupListEquality = ListEquality<Group>();
const ruleListEquality = ListEquality<Rule>();
const scriptListEquality = ListEquality<Script>();
const externalProviderListEquality = ListEquality<ExternalProvider>();
const packageListEquality = ListEquality<Package>();
const profileListEquality = ListEquality<Profile>();
const proxyGroupsEquality = ListEquality<ProxyGroup>();
const hotKeyActionListEquality = ListEquality<HotKeyAction>();
const stringAndStringMapEquality = MapEquality<String, String>();
const stringAndStringMapEntryListEquality =
    ListEquality<MapEntry<String, String>>();
const stringAndStringMapEntryIterableEquality =
    IterableEquality<MapEntry<String, String>>();
const stringAndObjectMapEntryIterableEquality =
    IterableEquality<MapEntry<String, Object?>>();
const delayMapEquality = MapEquality<String, Map<String, int?>>();
const stringSetEquality = SetEquality<String>();
const keyboardModifierListEquality = SetEquality<KeyboardModifier>();

const viewModeColumnsMap = {
  ViewMode.mobile: [2, 1],
  ViewMode.laptop: [3, 2],
  ViewMode.desktop: [4, 3],
};

const proxiesListStoreKey = PageStorageKey<String>('proxies_list');
const toolsStoreKey = PageStorageKey<String>('tools');
const profilesStoreKey = PageStorageKey<String>('profiles');

const defaultPrimaryColor = 0XFFD8C0C3;

double getWidgetHeight(num lines) {
  final space = 14.mAp;
  return max(lines * (80.ap + space) - space, 0);
}

const maxLength = 1000;

const mainIsolate = 'FlClashMainIsolate';

const serviceIsolate = 'FlClashServiceIsolate';

const defaultPrimaryColors = [
  0xFF795548,
  0xFF03A9F4,
  0xFFFFFF00,
  0XFFBBC9CC,
  0XFFABD397,
  defaultPrimaryColor,
  0XFF665390,
];

const scriptTemplate = '''
const main = (config) => {
  return config;
}''';

const backupDatabaseName = 'database.sqlite';
const configJsonName = 'config.json';
