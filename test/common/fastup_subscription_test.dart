import 'dart:convert';
import 'dart:typed_data';

import 'package:fl_clash/common/fastup_subscription.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('converts sing-box Fastup outbounds to Clash YAML', () {
    final source = jsonEncode({
      'outbounds': [
        {
          'type': 'trojan',
          'tag': 'Fastup fixture',
          'server': 'node.example',
          'server_port': 443,
          'password': 'synthetic-password',
          'mpw': 'rotated-mpw',
          'tls': {
            'enabled': true,
            'server_name': 'www.example.com',
            'insecure': true,
          },
          'multiplex': {'enabled': true},
        },
        {
          'type': 'selector',
          'tag': 'ignored',
          'outbounds': ['Fastup fixture'],
        },
      ],
    });

    final converted = convertFastupSubscriptionBytes(
      Uint8List.fromList(utf8.encode(source)),
    );
    final yaml = loadYaml(utf8.decode(converted)) as YamlMap;
    final proxies = yaml['proxies'] as YamlList;
    final proxy = proxies.single as YamlMap;

    expect(proxy['type'], 'trojan');
    expect(proxy['password'], 'synthetic-password#fastup');
    expect(proxy['mpw'], 'rotated-mpw');
    expect(proxy['sni'], 'www.example.com');
    expect(proxy['skip-cert-verify'], true);
    expect(
      ((yaml['proxy-groups'] as YamlList).single['proxies'] as YamlList)
          .toList(),
      ['Fastup fixture'],
    );
    expect((yaml['rules'] as YamlList).single, 'MATCH,GLOBAL');
  });

  test('leaves normal Clash YAML untouched', () {
    final bytes = Uint8List.fromList(
      utf8.encode('proxies:\n  - name: Standard\n    type: trojan\n'),
    );
    expect(convertFastupSubscriptionBytes(bytes), bytes);
  });
}
