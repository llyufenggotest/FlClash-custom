import 'package:fl_clash/common/oppa_yaml.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('Oppa create, refill, edit and save round trip', () {
    const original = OppaProxyConfig(
      name: 'Oppa fixture',
      server: 'node.example',
      port: 443,
      password: 'synthetic-token',
      sni: 'tls.example',
      preConnect: 8,
    );
    final restored = OppaProxyConfig.fromYaml(original.toYaml());
    expect(restored.name, original.name);
    expect(restored.password, original.password);
    expect(restored.preConnect, 8);

    final edited = OppaProxyConfig(
      name: restored.name,
      server: 'new.example',
      port: restored.port,
      password: restored.password,
      preConnect: 12,
    );
    final document = loadYaml(edited.toYaml()) as YamlMap;
    final proxy = (document['proxies'] as YamlList).single as YamlMap;
    expect(proxy['type'], 'oppa');
    expect(proxy['server'], 'new.example');
    expect(proxy['pre-connect'], 12);
    expect(proxy.containsKey('apiToken'), isFalse);
    expect(proxy.containsKey('encryptionKey'), isFalse);
  });

  test('rejects invalid ports, passwords and pre-connect', () {
    for (final config in [
      const OppaProxyConfig(name: 'bad', server: 'x', port: 0, password: 'x'),
      const OppaProxyConfig(name: 'bad', server: 'x', port: 443, password: ''),
      const OppaProxyConfig(name: 'bad', server: 'x', port: 443, password: 'x', preConnect: 65),
    ]) {
      expect(config.toYaml, throwsArgumentError);
    }
  });
}
