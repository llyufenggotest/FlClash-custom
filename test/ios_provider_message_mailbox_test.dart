import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String source(String path) => File(path).readAsStringSync();

  test('iOS provider messages have an App Group mailbox fallback', () {
    final controller = source('ios/Runner/Tunnel/TunnelController.swift');
    final runnerStore = source('ios/Runner/Storage/SharedStateStore.swift');
    final provider = source('ios/NECore/PacketTunnelProvider.swift');
    final extensionStore =
        source('ios/NECore/PacketTunnelSharedStateStore.swift');

    expect(controller, contains('sendProviderMessageViaMailbox'));
    expect(controller, contains('provider message mailbox fallback'));
    expect(runnerStore, contains('provider-message-mailbox'));
    expect(provider, contains('ProviderMessageMailbox'));
    expect(provider, contains('mailbox.start()'));
    expect(provider, contains('mailbox.stop()'));
    expect(extensionStore, contains('provider-message-mailbox'));
  });

  test('mailbox fallback is only entered after native nil response', () {
    final controller = source('ios/Runner/Tunnel/TunnelController.swift');
    final catchMarker = controller.indexOf(
      'where error.code == emptyReplyRetryCode',
    );
    final fallback = controller.indexOf(
      'try await sendProviderMessageViaMailbox',
    );
    expect(catchMarker, greaterThanOrEqualTo(0));
    expect(fallback, greaterThan(catchMarker));
  });
}
