import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('iOS keeps sqlite outside the shared App Group container', () {
    final source = File('lib/common/path.dart').readAsStringSync();
    expect(
      source,
      contains('Completer<Directory> supportDir = Completer();'),
    );
    expect(
      source,
      contains('final applicationSupportDir = await supportDirectory();'),
    );
    expect(source, contains('supportDir.complete(applicationSupportDir);'));
    expect(
      source,
      contains("return join((await supportDir.future).path, 'database.sqlite');"),
    );
  });
}
