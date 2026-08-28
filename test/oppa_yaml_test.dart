import 'package:fl_clash/common/oppa_yaml.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('serializes a native Oppa proxy without provider secrets', () {
    final output = oppaProxyYaml(
      name: 'Oppa fixture',
      server: 'node.example',
      port: 443,
      password: 'synthetic-token',
      sni: 'tls.example',
      udp: true,
      preConnect: 8,
    );

    final document = loadYaml(output) as YamlMap;
    final proxies = document['proxies'] as YamlList;
    final proxy = proxies.single as YamlMap;
    expect(proxy['name'], 'Oppa fixture');
    expect(proxy['type'], 'oppa');
    expect(proxy['server'], 'node.example');
    expect(proxy['port'], 443);
    expect(proxy['password'], 'synthetic-token');
    expect(proxy['sni'], 'tls.example');
    expect(proxy['udp'], isTrue);
    expect(proxy['pre-connect'], 8);
    expect(proxy.containsKey('apiToken'), isFalse);
    expect(proxy.containsKey('encryptionKey'), isFalse);
  });

  test('rejects invalid node credentials and ports', () {
    expect(
      () => oppaProxyYaml(
        name: 'bad',
        server: 'node.example',
        port: 0,
        password: 'token',
      ),
      throwsArgumentError,
    );
    expect(
      () => oppaProxyYaml(
        name: 'bad',
        server: 'node.example',
        port: 443,
        password: '',
      ),
      throwsArgumentError,
    );
  });
}
