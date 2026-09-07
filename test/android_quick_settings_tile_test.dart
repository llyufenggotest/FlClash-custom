import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('quick settings tile shows only the active nonblank profile', () {
    final source = File(
      'android/app/src/main/kotlin/com/follow/clash/TileService.kt',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    final stateUpdate = source.substring(
      source.indexOf('private fun updateTile(runState: RunState)'),
      source.indexOf('@SuppressLint', source.indexOf('private fun updateTile')),
    );

    expect(
      stateUpdate,
      contains('Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q'),
      reason: 'Tile.subtitle is available only from Android 10',
    );
    expect(
      stateUpdate,
      contains('subtitle = application.sharedState.currentProfileName.takeIf'),
    );
    expect(
      stateUpdate,
      contains('runState == RunState.STARTED && it.isNotBlank()'),
      reason: 'stopped or blank profiles must clear the subtitle',
    );
  });
}
