import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String source(String path) => File(path).readAsStringSync();

  test('provider messages have bounded, correlated diagnostics', () {
    final controller = source('ios/Runner/Tunnel/TunnelController.swift');
    expect(controller, contains('providerMessageTimeout'));
    expect(controller, contains('provider message begin seq='));
    expect(controller, contains('provider message timeout seq='));
    expect(controller, contains('ProviderMessageWaiter'));
  });

  test('post-start failures use one idempotent rollback path', () {
    final provider = source('ios/NECore/PacketTunnelProvider.swift');
    expect(provider, contains('rollbackPartialStart'));
    expect(provider, contains('quickSetup failed'));
    expect(provider, contains('startTun result='));
    expect(provider, contains('rollback reason='));
    expect(provider, contains('didStartEventQueue'));
    expect(provider, contains('didStartTun'));
  });

  test('extension stop completes after local cleanup without preference IO', () {
    final provider = source('ios/NECore/PacketTunnelProvider.swift');
    final stopStart = provider.indexOf('override func stopTunnel');
    final messageStart = provider.indexOf('override func handleAppMessage');
    final stopBody = provider.substring(stopStart, messageStart);
    expect(stopBody, isNot(contains('loadAllFromPreferences')));
    expect(stopBody, isNot(contains('saveToPreferences')));
    expect(stopBody, contains('completionHandler()'));
  });

  test('Runner owns on-demand preference changes during explicit stop', () {
    final coordinator = source('ios/Runner/Tunnel/TunnelCoordinator.swift');
    expect(coordinator, contains('stop disabled on-demand policy'));
    expect(coordinator, contains('manager.isOnDemandEnabled = false'));
  });

  test('native lifecycle diagnostics are merged into Flutter export', () {
    final provider = source('lib/providers/app.dart');
    final service = source('lib/plugins/service.dart');
    expect(provider, contains('===== iOS Runner / Network Extension ====='));
    expect(provider, contains('getNativeLogs'));
    expect(service, contains("invokeMethod<String>('getNativeLogs')"));
  });

  test('slow NECore startup is not force-stopped into an on-demand restart loop', () {
    final coordinator = source('ios/Runner/Tunnel/TunnelCoordinator.swift');
    expect(coordinator, contains('connectTimeout: TimeInterval = 30'));
    expect(coordinator, contains('startup still pending after timeout'));
    final runningStart = coordinator.indexOf('private func reconcileRunningTunnel');
    final runningEnd = coordinator.indexOf('private func settleBeforeStart');
    final runningBody = coordinator.substring(runningStart, runningEnd);
    expect(runningBody, isNot(contains('cleanUpFailedStart')));
    expect(coordinator, isNot(contains('failed start requested cleanup stop')));
    expect(coordinator, contains('settle still pending after timeout'));
  });

  test('extension has process-local resource heartbeat', () {
    final heartbeat = source('ios/NECore/NativeResourceHeartbeat.swift');
    final provider = source('ios/NECore/PacketTunnelProvider.swift');
    expect(heartbeat, contains('phys_footprint'));
    expect(heartbeat, contains('resident_mb='));
    expect(heartbeat, contains('footprint_mb='));
    expect(provider, contains('resourceHeartbeat.start()'));
    expect(provider, contains('resourceHeartbeat.stop()'));
  });

  test('only one process binds the profile DNS listener', () {
    final defaults = source('core/dns_listener_default.go');
    final iosApp = source('core/dns_listener_ios_app.go');
    final common = source('core/common.go');
    final hub = source('core/hub.go');
    final path = source('core/mihomo/constant/path.go');
    expect(defaults, contains('//go:build !(ios && !with_low_memory)'));
    expect(defaults, contains('disableDNSListener = false'));
    expect(defaults, contains('secondaryCacheFileName = ""'));
    expect(iosApp, contains('//go:build ios && !with_low_memory'));
    expect(iosApp, contains('disableDNSListener = true'));
    expect(iosApp, contains('network-extension'));
    expect(iosApp, contains('cache-app.db'));
    expect(common, contains('applyDNSListenerOwnership(currentConfig)'));
    expect(common, contains('cfg.DNS.Listen = ""'));
    expect(hub, contains('constant.SetCacheFileName(secondaryCacheFileName)'));
    expect(path, contains('func SetCacheFileName'));
    expect(path, contains('p.cacheFileName()'));
  });

  test('config reload returns pages to the OS on memory-constrained builds', () {
    final common = source('core/common.go');
    expect(common, contains('releaseReloadMemory()'));
    expect(common, contains('debug.FreeOSMemory()'));
    final start = common.indexOf('func releaseReloadMemory');
    final body = common.substring(start, start + 400);
    expect(body, contains('features.WithLowMemory'));
    expect(body, contains('features.IOS'));
  });

  test('native log rotation preserves line boundaries', () {
    for (final path in [
      'ios/NECore/NativeDiagnosticLog.swift',
      'ios/Runner/ServiceChannel.swift',
    ]) {
      final text = source(path);
      expect(text, contains('static func retainedTail'));
      expect(text, contains('firstIndex(of: 0x0A)'));
      expect(text, isNot(contains('data.suffix(min(data.count')));
      expect(text, contains('maxBytes: UInt64 = 4 * 1024 * 1024'));
    }
  });

  test('durable native log drops debug spam and keeps failure shapes', () {
    final log = source('ios/NECore/NativeDiagnosticLog.swift');
    final channel = source('ios/Runner/ServiceChannel.swift');
    final provider = source('ios/NECore/PacketTunnelProvider.swift');
    expect(log, contains('caseInsensitiveCompare("debug")'));
    expect(channel, contains('if call.method != "invokeMethod"'));
    for (final phase in [
      'startup_failure phase=vpn_options_missing',
      'startup_failure phase=set_network_settings_failed',
      'startup_failure phase=tunnel_fd_missing',
      'startup_failure phase=quick_setup_failed',
      'startup_failure phase=start_tun_failed',
    ]) {
      expect(provider, contains(phase));
    }
  });

  test('heartbeat warns before jetsam instead of only after the fact', () {
    final heartbeat = source('ios/NECore/NativeResourceHeartbeat.swift');
    expect(heartbeat, contains('memory_pressure_warning'));
    expect(heartbeat, contains('footprintWarningMB'));
  });
}
