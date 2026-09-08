import 'package:fl_clash/common/yaml.dart';
import 'package:yaml/yaml.dart';

class OppaProxyConfig {
  final String name;
  final String server;
  final int port;
  final String password;
  final String? sni;
  final bool skipCertVerify;
  final bool udp;
  final int? preConnect;

  const OppaProxyConfig({
    required this.name,
    required this.server,
    required this.port,
    required this.password,
    this.sni,
    this.skipCertVerify = false,
    this.udp = true,
    this.preConnect,
  });

  factory OppaProxyConfig.fromYaml(String source) {
    final document = loadYaml(source);
    if (document is! YamlMap || document['proxies'] is! YamlList) {
      throw const FormatException('Missing proxies list');
    }
    final proxies = document['proxies'] as YamlList;
    final proxy = proxies.cast<Object?>().whereType<YamlMap>().firstWhere(
      (entry) => entry['type']?.toString().toLowerCase() == 'oppa',
      orElse: () => throw const FormatException('Missing Oppa proxy'),
    );
    return OppaProxyConfig(
      name: proxy['name']?.toString() ?? '',
      server: proxy['server']?.toString() ?? '',
      port: int.tryParse(proxy['port']?.toString() ?? '') ?? 0,
      password: proxy['password']?.toString() ?? '',
      sni: proxy['sni']?.toString(),
      skipCertVerify: proxy['skip-cert-verify'] == true,
      udp: proxy['udp'] != false,
      preConnect: int.tryParse(proxy['pre-connect']?.toString() ?? ''),
    )..validate();
  }

  void validate() {
    if (name.trim().isEmpty) throw ArgumentError.value(name, 'name');
    if (server.trim().isEmpty) throw ArgumentError.value(server, 'server');
    if (port < 1 || port > 65535) throw ArgumentError.value(port, 'port');
    if (password.isEmpty || password.length > 4096) {
      throw ArgumentError.value(password.length, 'password');
    }
    if (preConnect != null && (preConnect! < 0 || preConnect! > 64)) {
      throw ArgumentError.value(preConnect, 'preConnect');
    }
  }

  String toYaml() {
    validate();
    return yaml.encode({
      'proxies': [
        {
          'name': name.trim(),
          'type': 'oppa',
          'server': server.trim(),
          'port': port,
          'password': password,
          if (sni?.trim().isNotEmpty == true) 'sni': sni!.trim(),
          if (skipCertVerify) 'skip-cert-verify': true,
          if (udp) 'udp': true,
          if (preConnect != null) 'pre-connect': preConnect,
        },
      ],
      'proxy-groups': [
        {
          'name': 'GLOBAL',
          'type': 'select',
          'proxies': [name.trim()],
        },
      ],
      'rules': ['MATCH,GLOBAL'],
    });
  }
}

String oppaProxyYaml({
  required String name,
  required String server,
  required int port,
  required String password,
  String? sni,
  bool skipCertVerify = false,
  bool udp = true,
  int? preConnect,
}) => OppaProxyConfig(
  name: name,
  server: server,
  port: port,
  password: password,
  sni: sni,
  skipCertVerify: skipCertVerify,
  udp: udp,
  preConnect: preConnect,
).toYaml();
