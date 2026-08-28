import 'package:fl_clash/common/yaml.dart';

/// Builds a minimal Mihomo YAML document containing one native Oppa proxy.
///
/// Provider credentials are intentionally not accepted here. This function
/// only serializes one runtime node and never emits provider apiToken or
/// encryptionKey fields.
String oppaProxyYaml({
  required String name,
  required String server,
  required int port,
  required String password,
  String? sni,
  bool skipCertVerify = false,
  bool udp = true,
  int? preConnect,
}) {
  if (name.trim().isEmpty) throw ArgumentError.value(name, 'name');
  if (server.trim().isEmpty) throw ArgumentError.value(server, 'server');
  if (port < 1 || port > 65535) throw ArgumentError.value(port, 'port');
  if (password.isEmpty || password.length > 4096) {
    throw ArgumentError.value(password.length, 'password');
  }
  if (preConnect != null && (preConnect < 0 || preConnect > 64)) {
    throw ArgumentError.value(preConnect, 'preConnect');
  }

  final proxy = <String, Object?>{
    'name': name,
    'type': 'oppa',
    'server': server,
    'port': port,
    'password': password,
    if (sni?.trim().isNotEmpty == true) 'sni': sni!.trim(),
    if (skipCertVerify) 'skip-cert-verify': true,
    if (udp) 'udp': true,
    if (preConnect != null) 'pre-connect': preConnect,
  };
  return yaml.encode({'proxies': [proxy]});
}
