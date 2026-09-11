import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String source(String path) => File(path).readAsStringSync();

  test('iOS uses a conservative MTU without changing other platforms', () {
    final state = source('lib/providers/state/system.dart');
    expect(state, contains('final effectiveMtu = system.isIOS'));
    expect(state, contains('mtu.clamp(1280, 1500)'));
    expect(state, contains('mtu: effectiveMtu'));
  });

  test('the Network Extension applies the effective MTU consistently', () {
    final provider = source('ios/NECore/PacketTunnelProvider.swift');
    final network = source('ios/NECore/PacketTunnelNetworkConfiguration.swift');
    expect(network, contains('settings.mtu = NSNumber(value: options.mtu)'));
    expect(provider, contains('mtu: vpnOptions.mtu'));
  });
}
