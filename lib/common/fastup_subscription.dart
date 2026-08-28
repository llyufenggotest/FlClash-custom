import 'dart:convert';
import 'dart:typed_data';

import 'package:fl_clash/common/yaml.dart';

Uint8List convertFastupSubscriptionBytes(Uint8List bytes) {
  final text = utf8.decode(bytes, allowMalformed: true).trimLeft();
  if (!text.startsWith('{')) return bytes;

  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    return bytes;
  }
  if (decoded is! Map<String, dynamic>) return bytes;
  final outbounds = decoded['outbounds'];
  if (outbounds is! List) return bytes;

  final proxies = <Map<String, Object?>>[];
  for (final outbound in outbounds) {
    if (outbound is! Map || outbound['type'] != 'trojan') continue;
    final mpw = outbound['mpw'];
    if (mpw is! String || mpw.isEmpty) continue;

    final passwordValue = outbound['password'];
    final password = passwordValue is String ? passwordValue : '';
    final tlsValue = outbound['tls'];
    final tls = tlsValue is Map ? tlsValue : const <String, Object?>{};
    final nameValue = outbound['tag'];
    final serverValue = outbound['server'];
    final portValue = outbound['server_port'];
    if (nameValue is! String || serverValue is! String || portValue is! num || password.isEmpty) continue;

    proxies.add({
      'name': nameValue,
      'type': 'trojan',
      'server': serverValue,
      'port': portValue.toInt(),
      'password': password.endsWith('#fastup') ? password : '$password#fastup',
      'mpw': mpw,
      if (tls['server_name'] case final String serverName when serverName.isNotEmpty) 'sni': serverName,
      if (tls['insecure'] is bool) 'skip-cert-verify': tls['insecure'] as bool,
      'udp': true,
    });
  }
  if (proxies.isEmpty) return bytes;

  final names = proxies.map((proxy) => proxy['name'] as String).toList();
  return Uint8List.fromList(utf8.encode(yaml.encode({
    'mixed-port': 7890,
    'allow-lan': false,
    'mode': 'rule',
    'log-level': 'info',
    'proxies': proxies,
    'proxy-groups': [{'name': 'GLOBAL', 'type': 'select', 'proxies': names}],
    'rules': ['MATCH,GLOBAL'],
  })));
}
