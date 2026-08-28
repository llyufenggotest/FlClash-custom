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

  test('extension has process-local resource heartbeat', () {
    final heartbeat = source('ios/NECore/NativeResourceHeartbeat.swift');
    final provider = source('ios/NECore/PacketTunnelProvider.swift');
    expect(heartbeat, contains('phys_footprint'));
    expect(heartbeat, contains('resident_mb='));
    expect(heartbeat, contains('footprint_mb='));
    expect(provider, contains('resourceHeartbeat.start()'));
    expect(provider, contains('resourceHeartbeat.stop()'));
  });
}
