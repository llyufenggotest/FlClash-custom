import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

const _defaultRuleProviderLimit = 32 * 1024 * 1024;
const _classicalRuleLimit = 10000;

typedef RuleProviderDownload =
    Future<RuleProviderFileDownload> Function(
      String url,
      Map<String, String> headers,
      int sizeLimit,
      String destinationPath,
    );

class RuleGenerationPreparation {
  final String fingerprint;
  final String config;
  final String generation;
  final String configPath;

  const RuleGenerationPreparation({
    required this.fingerprint,
    required this.config,
    required this.generation,
    required this.configPath,
  });
}

class RuleGenerationPreparer {
  final CoreInterface core;
  final RuleProviderDownload _download;
  final Future<String> Function() _homeDir;

  RuleGenerationPreparer({
    required this.core,
    RuleProviderDownload? download,
    Future<String> Function()? homeDir,
  }) : _download = download ?? _downloadWithSharedRequest,
       _homeDir = homeDir ?? (() => appPath.homeDirPath);

  Future<RuleGenerationPreparation?> findPrepared({
    required int profileId,
    required String config,
  }) async {
    final fingerprint = _sha256String(config);
    final result = await core.getPreparedRuleGeneration(
      profileId: profileId,
      fingerprint: fingerprint,
    );
    final path = result['config-path'];
    final generation = result['generation'];
    if (path is! String || path.isEmpty || generation is! String) return null;
    return RuleGenerationPreparation(
      fingerprint: fingerprint,
      config: await File(path).readAsString(),
      generation: generation,
      configPath: path,
    );
  }

  Future<RuleGenerationPreparation> prepare({
    required int profileId,
    required String config,
  }) async {
    final fingerprint = _sha256String(config);
    final existing = await findPrepared(profileId: profileId, config: config);
    if (existing != null) return existing;

    final document = _stringMap(loadYaml(config));
    final providers = _stringMap(document['rule-providers']);
    final home = await _homeDir();
    final profileRoot = p.join(home, 'prewarm', '$profileId');
    final staging = Directory(
      p.join(
        profileRoot,
        'staging',
        'download_${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    await staging.create(recursive: true);

    try {
      final prepared = <_PreparedProvider>[];
      for (final entry in providers.entries) {
        final definition = _stringMap(entry.value);
        final type = definition['type']?.toString() ?? '';
        if (type == 'inline') continue;
        final behavior = definition['behavior']?.toString() ?? 'domain';
        final stableId = _sha256String(entry.key);
        final stagingRaw = p.join(staging.path, 'rules', '$stableId.raw');
        final download = await _loadProvider(entry.key, definition, stagingRaw);
        if (p.normalize(download.path) != p.normalize(stagingRaw)) {
          throw StateError(
            'rule provider "${entry.key}" wrote outside controlled staging',
          );
        }
        final actualDigest = await _fileSHA256(download.path);
        if (actualDigest != download.sha256.toLowerCase()) {
          throw StateError(
            'rule provider "${entry.key}" download digest mismatch',
          );
        }
        if (behavior == 'classical') {
          final info = await File(download.path).stat();
          if (info.size > _defaultRuleProviderLimit) {
            throw StateError('rule provider "${entry.key}" exceeds size-limit');
          }
          final count = await _classicalRuleCount(download.path, definition);
          if (count > _classicalRuleLimit) {
            throw StateError(
              'rule provider "${entry.key}" exceeds classical rule limit of $_classicalRuleLimit ($count rules)',
            );
          }
        }
        prepared.add(
          _PreparedProvider(
            entry.key,
            definition,
            download.path,
            download.sha256,
            compileMRS: behavior != 'classical',
          ),
        );
      }

      final identity = jsonEncode({
        'version': 2,
        'compiler': 'MRS-SC02',
        'profile-id': profileId,
        'fingerprint': fingerprint,
        'providers': [
          for (final provider in prepared)
            {
              'name': provider.name,
              'definition': provider.definition,
              'raw-sha256': provider.rawSha256,
            },
        ],
      });
      final generation = _sha256String(identity);
      final finalRoot = p.join(profileRoot, 'generations', generation);
      final artifacts = <Map<String, dynamic>>[];
      for (final provider in prepared) {
        final stableId = _sha256String(provider.name);
        final stagingRaw = provider.rawPath;
        final finalRaw = p.join(finalRoot, 'rules', '$stableId.raw');
        Map<String, dynamic> artifact;
        if (provider.compileMRS) {
          final result = await core.prewarmRuleProvider(
            name: provider.name,
            definition: provider.definition,
            targetPath: stagingRaw,
          );
          final stagingMRS = result['sidecar']?.toString() ?? '$stagingRaw.mrs';
          artifact = {
            'name': provider.name,
            'raw-path': stagingRaw,
            'raw-sha256': provider.rawSha256,
            'mrs-path': stagingMRS,
            'mrs-sha256': await _fileSHA256(stagingMRS),
          };
        } else {
          artifact = {
            'name': provider.name,
            'raw-path': stagingRaw,
            'raw-sha256': provider.rawSha256,
          };
        }
        final mapping = _stringMap(providers[provider.name]);
        mapping
          ..['type'] = 'file'
          ..['path'] = finalRaw
          ..remove('url')
          ..remove('proxy')
          ..remove('interval')
          ..remove('size-limit');
        providers[provider.name] = mapping;
        artifacts.add(artifact);
      }
      document['rule-providers'] = providers;
      final finalConfig = await encodeYamlTask(document);
      final stagingConfig = p.join(staging.path, 'config.yaml');
      await File(stagingConfig).writeAsString(finalConfig, flush: true);
      final published = await core.publishRuleGeneration(
        profileId: profileId,
        fingerprint: fingerprint,
        generation: generation,
        stagingPath: staging.path,
        configPath: stagingConfig,
        artifacts: artifacts,
      );
      final configPath = published['config-path']?.toString();
      if (configPath == null || configPath.isEmpty) {
        throw StateError('core did not publish a rule generation config');
      }
      return RuleGenerationPreparation(
        fingerprint: fingerprint,
        config: await File(configPath).readAsString(),
        generation: generation,
        configPath: configPath,
      );
    } catch (_) {
      if (await staging.exists()) await staging.delete(recursive: true);
      rethrow;
    }
  }

  Future<RuleProviderFileDownload> _loadProvider(
    String name,
    Map<String, dynamic> definition,
    String destinationPath,
  ) async {
    final type = definition['type']?.toString();
    switch (type) {
      case 'http':
        final proxy = definition['proxy']?.toString() ?? '';
        if (proxy.isNotEmpty && proxy != 'DIRECT') {
          throw UnsupportedError(
            'rule provider "$name" proxy "$proxy" is not supported by isolated prewarm',
          );
        }
        final url = definition['url']?.toString() ?? '';
        final uri = Uri.tryParse(url);
        if (uri == null ||
            !uri.hasScheme ||
            !{'http', 'https'}.contains(uri.scheme)) {
          throw FormatException(
            'rule provider "$name" has an invalid HTTP URL',
          );
        }
        return _download(
          url,
          _headers(definition['header']),
          _sizeLimit(definition),
          destinationPath,
        );
      case 'file':
        final path = definition['path']?.toString() ?? '';
        if (path.isEmpty || !p.isAbsolute(path)) {
          throw StateError('rule provider "$name" file path must be absolute');
        }
        final file = File(p.normalize(path));
        final info = await file.stat();
        if (info.type != FileSystemEntityType.file) {
          throw StateError('rule provider "$name" is not a regular file');
        }
        final limit = _sizeLimit(definition);
        if (info.size > limit) {
          throw StateError('rule provider "$name" exceeds size-limit');
        }
        await File(destinationPath).parent.create(recursive: true);
        final digestSink = SingleValueSink<Digest>();
        final hashSink = sha256.startChunkedConversion(digestSink);
        var hashClosed = false;
        try {
          final output = File(destinationPath).openWrite();
          await file
              .openRead()
              .map((chunk) {
                hashSink.add(chunk);
                return chunk;
              })
              .pipe(output);
          hashSink.close();
          hashClosed = true;
          return RuleProviderFileDownload(
            path: destinationPath,
            length: info.size,
            sha256: digestSink.value.toString(),
            headers: Headers(),
          );
        } finally {
          if (!hashClosed) hashSink.close();
        }
      default:
        throw UnsupportedError(
          'rule provider "$name" has unsupported type "$type"',
        );
    }
  }

  static Future<RuleProviderFileDownload> _downloadWithSharedRequest(
    String url,
    Map<String, String> headers,
    int sizeLimit,
    String destinationPath,
  ) {
    return request.downloadRuleProviderToFile(
      url: url,
      headers: headers,
      sizeLimit: sizeLimit,
      destinationPath: destinationPath,
    );
  }
}

class _PreparedProvider {
  final String name;
  final Map<String, dynamic> definition;
  final String rawPath;
  final String rawSha256;
  final bool compileMRS;
  const _PreparedProvider(
    this.name,
    this.definition,
    this.rawPath,
    this.rawSha256, {
    required this.compileMRS,
  });
}

Map<String, dynamic> _stringMap(Object? value) {
  if (value is! Map) return <String, dynamic>{};
  return {
    for (final entry in value.entries)
      entry.key.toString(): _plain(entry.value),
  };
}

Object? _plain(Object? value) {
  if (value is Map) return _stringMap(value);
  if (value is List) return value.map(_plain).toList();
  return value;
}

Map<String, String> _headers(Object? value) {
  final source = _stringMap(value);
  return {
    for (final entry in source.entries)
      entry.key: entry.value is List
          ? (entry.value as List).map((item) => item.toString()).join(', ')
          : entry.value.toString(),
  };
}

Future<int> _classicalRuleCount(
  String path,
  Map<String, dynamic> definition,
) async {
  final format = definition['format']?.toString() ?? 'yaml';
  if (format == 'text') {
    var count = 0;
    await for (final line in File(
      path,
    ).openRead().transform(utf8.decoder).transform(const LineSplitter())) {
      final value = line.trim();
      if (value.isNotEmpty && !value.startsWith('#')) {
        count++;
        if (count > _classicalRuleLimit) return count;
      }
    }
    return count;
  }
  final text = await File(path).readAsString();
  if (format != 'yaml') {
    throw UnsupportedError(
      'classical rule provider format "$format" is not supported by isolated prewarm',
    );
  }
  final document = loadYaml(text);
  final payload = document is Map ? document['payload'] : null;
  if (payload is! List) {
    throw const FormatException(
      'classical YAML rule provider must contain a payload list',
    );
  }
  return payload.length;
}

int _sizeLimit(Map<String, dynamic> definition) {
  final value = definition['size-limit'];
  final parsed = value is int ? value : int.tryParse(value?.toString() ?? '');
  if (parsed == null || parsed <= 0) return _defaultRuleProviderLimit;
  return parsed > _defaultRuleProviderLimit
      ? _defaultRuleProviderLimit
      : parsed;
}

String _sha256String(String value) => _sha256Bytes(utf8.encode(value));
String _sha256Bytes(List<int> value) => sha256.convert(value).toString();
Future<String> _fileSHA256(String path) async =>
    (await sha256.bind(File(path).openRead()).first).toString();
