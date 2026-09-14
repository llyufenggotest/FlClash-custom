import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/core/rule_generation_preparation.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

const _defaultRuleProviderLimit = 32 * 1024 * 1024;
const _classicalRuleLimit = 10000;
const _providerDownloadConcurrency = 4;
const _providerDownloadMaxAttempts = 3;
const _providerDownloadRetryBase = Duration(milliseconds: 250);
const _providerDownloadRetryCap = Duration(seconds: 1);
const _providerDownloadDeadline = Duration(seconds: 60);
const _providerDownloadAttemptCap = Duration(seconds: 20);

class _AsyncLimiter {
  final int limit;
  int _active = 0;
  final List<Completer<void>> _waiters = [];

  _AsyncLimiter(this.limit);

  Future<T> run<T>(Future<T> Function() operation) async {
    if (_active >= limit) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    }
    _active++;
    try {
      return await operation();
    } finally {
      _active--;
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete();
      }
    }
  }
}

final Map<String, Future<void>> _providerCacheFlights = {};
int _cacheNonce = 0;

typedef RuleProviderDownload =
    Future<RuleProviderFileDownload> Function(
      String url,
      Map<String, String> headers,
      int sizeLimit,
      String destinationPath,
      Duration timeout,
      CancelToken cancelToken,
    );

class RuleGenerationPreparer {
  final CoreInterface core;
  final RuleProviderDownload _download;
  final Future<String> Function() _homeDir;
  final Future<void> Function(Duration duration) _sleeper;
  final DateTime Function() _clock;
  final double Function() _retryJitter;
  final Duration _downloadDeadline;
  final Duration _downloadAttemptCap;
  final void Function(RulePreparationProgress progress)? _onProgress;
  int _activeProfileId = 0;
  late final String _operationId =
      '${pid}_${DateTime.now().microsecondsSinceEpoch}';

  RuleGenerationPreparer({
    required this.core,
    RuleProviderDownload? download,
    Future<String> Function()? homeDir,
    Future<void> Function(Duration duration)? sleeper,
    DateTime Function()? clock,
    double Function()? retryJitter,
    Duration downloadDeadline = _providerDownloadDeadline,
    Duration downloadAttemptCap = _providerDownloadAttemptCap,
    void Function(RulePreparationProgress progress)? onProgress,
  }) : _download = download ?? _downloadWithSharedRequest,
       _homeDir = homeDir ?? (() => appPath.homeDirPath),
       _sleeper = sleeper ?? Future<void>.delayed,
       _clock = clock ?? DateTime.now,
       _retryJitter = retryJitter ?? Random().nextDouble,
       _downloadDeadline = downloadDeadline,
       _downloadAttemptCap = downloadAttemptCap,
       _onProgress = onProgress {
    if (downloadDeadline <= Duration.zero) {
      throw ArgumentError.value(
        downloadDeadline,
        'downloadDeadline',
        'must be positive',
      );
    }
    if (downloadAttemptCap <= Duration.zero) {
      throw ArgumentError.value(
        downloadAttemptCap,
        'downloadAttemptCap',
        'must be positive',
      );
    }
  }

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
    _activeProfileId = profileId;
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
      // A timed-out preparation must not leave work holding permits needed by
      // a later profile switch. Concurrency is shared only within this run.
      final limiter = _AsyncLimiter(_providerDownloadConcurrency);
      final proxyProviders = _stringMap(document['proxy-providers']);
      final proxyEntries = proxyProviders.entries.where((entry) {
        final definition = _stringMap(entry.value);
        return definition['type']?.toString() != 'inline';
      }).toList();
      final proxyResultsFuture = _mapWithLimit(proxyEntries, (entry) async {
        return limiter.run(() async {
          final definition = _stringMap(entry.value);
          final stableId = _sha256String(entry.key);
          final stagingRaw = p.join(staging.path, 'proxies', '$stableId.yaml');
          final cacheRoot = p.join(home, 'prewarm', 'cache');
          _progress(
            RulePreparationPhase.queued,
            kind: 'proxy',
            name: entry.key,
            path: stagingRaw,
          );
          final cached = await _readCachedProvider(
            cacheRoot,
            definition,
            stagingRaw,
            kind: 'proxy',
          );
          final effectiveDefinition = cached == null
              ? definition
              : (<String, dynamic>{
                    ...definition,
                    'type': 'file',
                    'path': cached.path,
                  }
                  ..remove('url')
                  ..remove('interval'));
          if (cached != null) {
            _progress(
              RulePreparationPhase.cacheHit,
              kind: 'proxy',
              name: entry.key,
              path: stagingRaw,
            );
          } else {
            _progress(
              RulePreparationPhase.downloading,
              kind: 'proxy',
              name: entry.key,
              path: stagingRaw,
            );
          }
          final result = await _prewarmProxyProvider(
            entry.key,
            effectiveDefinition,
            stagingRaw,
          );
          final actualPath = result['path']?.toString();
          final digest = result['digest']?.toString();
          final count = result['count'];
          if (actualPath == null ||
              p.normalize(actualPath) != p.normalize(stagingRaw) ||
              digest == null ||
              digest.isEmpty ||
              count is! num ||
              count <= 0) {
            throw StateError(
              'proxy provider "${entry.key}" was not fully validated',
            );
          }
          if (await _fileSHA256(actualPath) != digest.toLowerCase()) {
            throw StateError('proxy provider "${entry.key}" digest mismatch');
          }
          if (cached == null) {
            final info = await File(actualPath).stat();
            await _writeCachedProvider(
              cacheRoot,
              definition,
              RuleProviderFileDownload(
                path: actualPath,
                length: info.size,
                sha256: digest,
                headers: Headers(),
              ),
              kind: 'proxy',
            );
          }
          _progress(
            RulePreparationPhase.complete,
            kind: 'proxy',
            name: entry.key,
            path: actualPath,
          );
          return _PreparedProxyProvider(
            entry.key,
            definition,
            actualPath,
            digest,
          );
        });
      });

      final ruleEntries = providers.entries.where((entry) {
        final definition = _stringMap(entry.value);
        return definition['type']?.toString() != 'inline';
      }).toList();
      final preparedResultsFuture = _mapWithLimit(ruleEntries, (entry) async {
        return limiter.run(() async {
          final definition = _stringMap(entry.value);
          final behavior = definition['behavior']?.toString() ?? 'domain';
          final stableId = _sha256String(entry.key);
          final stagingRaw = p.join(staging.path, 'rules', '$stableId.raw');
          _progress(
            RulePreparationPhase.queued,
            kind: 'rule',
            name: entry.key,
            path: stagingRaw,
          );
          _progress(
            RulePreparationPhase.downloading,
            kind: 'rule',
            name: entry.key,
            path: stagingRaw,
          );
          final download = await _loadProvider(
            entry.key,
            definition,
            stagingRaw,
            cacheRoot: p.join(home, 'prewarm', 'cache'),
          );
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
              throw StateError(
                'rule provider "${entry.key}" exceeds size-limit',
              );
            }
            final count = await _classicalRuleCount(download.path, definition);
            if (count > _classicalRuleLimit) {
              throw StateError(
                'rule provider "${entry.key}" exceeds classical rule limit of $_classicalRuleLimit ($count rules)',
              );
            }
          }
          _progress(
            RulePreparationPhase.complete,
            kind: 'rule',
            name: entry.key,
            path: download.path,
          );
          return _PreparedProvider(
            entry.key,
            definition,
            download.path,
            download.sha256,
            compileMRS: behavior != 'classical',
          );
        });
      });
      final settled = await _settleBoth(
        proxyResultsFuture,
        preparedResultsFuture,
      );
      final preparedProxies = settled.$1;
      final prepared = settled.$2;

      final identity = jsonEncode({
        'version': 2,
        'compiler': 'MRS-SC02',
        'profile-id': profileId,
        'fingerprint': fingerprint,
        'proxy-providers': [
          for (final provider in preparedProxies)
            {
              'name': provider.name,
              'definition': provider.definition,
              'raw-sha256': provider.rawSha256,
            },
        ],
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
          _progress(
            RulePreparationPhase.compiling,
            kind: 'rule',
            name: provider.name,
            path: stagingRaw,
          );
          final result = await limiter.run(
            () => core.prewarmRuleProvider(
              name: provider.name,
              definition: provider.definition,
              targetPath: stagingRaw,
            ),
          );
          final stagingMRS = result['sidecar']?.toString() ?? '$stagingRaw.mrs';
          artifact = {
            'name': 'rule:${provider.name}',
            'raw-path': stagingRaw,
            'raw-sha256': provider.rawSha256,
            'mrs-path': stagingMRS,
            'mrs-sha256': await _fileSHA256(stagingMRS),
          };
        } else {
          artifact = {
            'name': 'rule:${provider.name}',
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
      for (final provider in preparedProxies) {
        final stableId = _sha256String(provider.name);
        final finalRaw = p.join(finalRoot, 'proxies', '$stableId.yaml');
        final mapping = _stringMap(proxyProviders[provider.name]);
        mapping
          ..['type'] = 'file'
          ..['path'] = finalRaw
          ..remove('url')
          ..remove('proxy')
          ..remove('interval')
          ..remove('size-limit');
        proxyProviders[provider.name] = mapping;
        artifacts.add({
          'name': 'proxy:${provider.name}',
          'raw-path': provider.rawPath,
          'raw-sha256': provider.rawSha256,
        });
      }
      document['proxy-providers'] = proxyProviders;
      document['rule-providers'] = providers;
      final finalConfig = await encodeYamlTask(document);
      final stagingConfig = p.join(staging.path, 'config.yaml');
      await File(stagingConfig).writeAsString(finalConfig, flush: true);
      _progress(
        RulePreparationPhase.validating,
        kind: 'generation',
        name: generation,
        path: stagingConfig,
      );
      final validation = await core.validateStagedConfigAtPath(
        profileId: profileId,
        stagingPath: staging.path,
        candidateConfigPath: stagingConfig,
      );
      if (validation.isNotEmpty) {
        throw StateError('candidate configuration is invalid: $validation');
      }
      _progress(
        RulePreparationPhase.commit,
        kind: 'generation',
        name: generation,
        path: stagingConfig,
      );
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
      _progress(
        RulePreparationPhase.complete,
        kind: 'generation',
        name: generation,
        path: configPath,
      );
      return RuleGenerationPreparation(
        fingerprint: fingerprint,
        config: await File(configPath).readAsString(),
        generation: generation,
        configPath: configPath,
      );
    } catch (error, stackTrace) {
      _progress(
        RulePreparationPhase.error,
        kind: 'generation',
        name: '$profileId',
        path: staging.path,
        error: error,
      );
      if (await staging.exists()) await staging.delete(recursive: true);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<Map<String, dynamic>> _prewarmProxyProvider(
    String name,
    Map<String, dynamic> definition,
    String targetPath,
  ) async {
    var attempts = 0;
    final deadline = _clock().add(_downloadDeadline);
    Object? lastError;
    while (attempts < _providerDownloadMaxAttempts) {
      final remaining = deadline.difference(_clock());
      if (remaining <= Duration.zero) {
        lastError ??= TimeoutException(
          'proxy provider prewarm deadline expired',
          _downloadDeadline,
        );
        break;
      }
      attempts++;
      final attemptTimeout = remaining < _downloadAttemptCap
          ? remaining
          : _downloadAttemptCap;
      final attemptPath = '$targetPath.attempt.$attempts';
      await _removeStagingTarget(targetPath);
      await _removeStagingTarget(attemptPath);
      try {
        final result = await core
            .prewarmProxyProvider(
              name: name,
              definition: definition,
              targetPath: attemptPath,
              timeoutMilliseconds: attemptTimeout.inMilliseconds,
            )
            .timeout(attemptTimeout);
        final actualPath = result['path']?.toString();
        if (actualPath == null ||
            p.normalize(actualPath) != p.normalize(attemptPath)) {
          throw StateError(
            'proxy provider "$name" wrote outside its attempt staging target',
          );
        }
        await _removeStagingTarget(targetPath);
        await File(attemptPath).rename(targetPath);
        return {...result, 'path': targetPath};
      } on Object catch (error) {
        lastError = error;
        await _removeStagingTarget(attemptPath);
        final canRetry =
            attempts < _providerDownloadMaxAttempts &&
            _isTransientProxyPrewarmError(error);
        if (!canRetry) break;
        final delay = _retryDelay(attempts);
        final retryRemaining = deadline.difference(_clock());
        if (retryRemaining <= delay) break;
        await _sleeper(delay);
      }
    }
    throw StateError(
      'proxy provider "$name" prewarm failed after $attempts attempt${attempts == 1 ? '' : 's'}: '
      '${compactError(lastError ?? TimeoutException('prewarm failed'))}',
    );
  }

  Future<void> _removeStagingTarget(String targetPath) async {
    final target = File(targetPath);
    if (await target.exists()) await target.delete();
    final parent = target.parent;
    if (!await parent.exists()) return;
    await for (final entity in parent.list(followLinks: false)) {
      if (entity is File &&
          p.basename(entity.path).startsWith('${p.basename(targetPath)}.') &&
          entity.path.endsWith('.tmp')) {
        await entity.delete();
      }
    }
  }

  bool _isTransientProxyPrewarmError(Object error) {
    if (error is TimeoutException) return true;
    if (error is! CoreMethodException || error.code != 'core_error') {
      return error is CoreMethodException && error.isCoreUnavailable;
    }
    final message = error.message.toLowerCase();
    if (RegExp(r'(^|\D)(408|425|429|5\d\d)(\D|$)').hasMatch(message)) {
      return true;
    }
    return const [
      'context deadline exceeded',
      'deadline exceeded',
      'operation was canceled',
      'operation was cancelled',
      'context canceled',
      'context cancelled',
      'i/o timeout',
      'connection timed out',
      'connection timeout',
      'connection reset',
      'connection refused',
      'network is unreachable',
      'no route to host',
      'temporary failure',
      'temporarily unavailable',
      'unexpected eof',
      'tls handshake timeout',
      'server misbehaving',
    ].any(message.contains);
  }

  Future<RuleProviderFileDownload> _loadProvider(
    String name,
    Map<String, dynamic> definition,
    String destinationPath, {
    required String cacheRoot,
  }) async {
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
        final cached = await _readCachedProvider(
          cacheRoot,
          definition,
          destinationPath,
        );
        if (cached != null) return cached;
        RuleProviderFileDownload downloaded;
        var attempts = 0;
        final deadline = _clock().add(_downloadDeadline);
        Object? lastError;
        while (attempts < _providerDownloadMaxAttempts) {
          final remaining = deadline.difference(_clock());
          if (remaining <= Duration.zero) {
            lastError ??= TimeoutException(
              'rule provider download deadline expired',
              _downloadDeadline,
            );
            break;
          }
          attempts++;
          final attemptTimeout = remaining < _downloadAttemptCap
              ? remaining
              : _downloadAttemptCap;
          final cancelToken = CancelToken();
          try {
            downloaded = await _runDownloadAttempt(
              () => _download(
                url,
                _headers(definition['header']),
                _sizeLimit(definition),
                destinationPath,
                attemptTimeout,
                cancelToken,
              ),
              timeout: attemptTimeout,
              cancelToken: cancelToken,
              url: url,
            );
            final verified = await _verifyDownload(downloaded);
            await _writeCachedProvider(cacheRoot, definition, verified);
            return verified;
          } on Object catch (error) {
            lastError = error;
            final canRetry =
                attempts < _providerDownloadMaxAttempts &&
                _isTransientDownloadError(error);
            if (!canRetry) break;
            final delay = _retryDelay(attempts);
            final retryRemaining = deadline.difference(_clock());
            if (retryRemaining <= delay) break;
            await _sleeper(delay);
          }
        }
        throw StateError(
          'rule provider "$name" download failed after $attempts attempt${attempts == 1 ? '' : 's'}: '
          '${compactError(lastError ?? TimeoutException('download failed'))}',
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

  Future<RuleProviderFileDownload> _runDownloadAttempt(
    Future<RuleProviderFileDownload> Function() operation, {
    required Duration timeout,
    required CancelToken cancelToken,
    required String url,
  }) async {
    try {
      return await operation().timeout(
        timeout,
        onTimeout: () {
          cancelToken.cancel('rule provider download attempt timed out');
          throw DioException(
            requestOptions: RequestOptions(path: url),
            type: DioExceptionType.receiveTimeout,
            error: TimeoutException(
              'rule provider download attempt exceeded $timeout',
              timeout,
            ),
          );
        },
      );
    } finally {
      if (!cancelToken.isCancelled) {
        cancelToken.cancel('rule provider download attempt complete');
      }
    }
  }

  Duration _retryDelay(int failedAttempt) {
    final exponential =
        _providerDownloadRetryBase.inMilliseconds * (1 << (failedAttempt - 1));
    final capped = min(exponential, _providerDownloadRetryCap.inMilliseconds);
    final jitterSample = _retryJitter();
    final normalizedJitter = jitterSample.isFinite
        ? jitterSample.clamp(0.0, 1.0).toDouble()
        : 0.0;
    final jitter = (normalizedJitter * capped * 0.25).round();
    return Duration(milliseconds: capped + jitter);
  }

  bool _isTransientDownloadError(Object error) {
    if (error is! DioException) return false;
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
      case DioExceptionType.connectionError:
        return true;
      case DioExceptionType.badResponse:
        final status = error.response?.statusCode;
        return status == 429 ||
            (status != null && status >= 500 && status < 600);
      case DioExceptionType.cancel:
      case DioExceptionType.badCertificate:
      case DioExceptionType.unknown:
        return false;
    }
  }

  Future<RuleProviderFileDownload> _verifyDownload(
    RuleProviderFileDownload download,
  ) async {
    final digest = await _fileSHA256(download.path);
    if (digest != download.sha256.toLowerCase()) {
      throw StateError('download digest mismatch');
    }
    return download;
  }

  Future<RuleProviderFileDownload?> _readCachedProvider(
    String root,
    Map<String, dynamic> definition,
    String destinationPath, {
    String kind = 'rule',
  }) async {
    final identity = _providerIdentity(definition, kind: kind);
    final metadata = File(p.join(root, '$identity.json'));
    if (!await metadata.exists()) return null;
    try {
      final record = jsonDecode(await metadata.readAsString());
      if (record is! Map || record['identity'] != identity) return null;
      final cachedAt = DateTime.tryParse(record['cached-at']?.toString() ?? '');
      final intervalSeconds =
          int.tryParse(definition['interval']?.toString() ?? '') ?? 86400;
      if (cachedAt == null ||
          intervalSeconds <= 0 ||
          DateTime.now().difference(cachedAt) >=
              Duration(seconds: intervalSeconds)) {
        return null;
      }
      final digest = record['sha256']?.toString().toLowerCase();
      if (digest == null || digest.length != 64) return null;
      final source = File(p.join(root, '$digest.raw'));
      final info = await source.stat();
      if (info.type != FileSystemEntityType.file ||
          info.size > _sizeLimit(definition) ||
          await _fileSHA256(source.path) != digest) {
        return null;
      }
      await File(destinationPath).parent.create(recursive: true);
      final temporaryDestination = File(
        '$destinationPath.tmp.$pid.${DateTime.now().microsecondsSinceEpoch}.${_cacheNonce++}',
      );
      try {
        await source.copy(temporaryDestination.path);
        if (await _fileSHA256(temporaryDestination.path) != digest) {
          return null;
        }
        if (await File(destinationPath).exists()) {
          await File(destinationPath).delete();
        }
        await temporaryDestination.rename(destinationPath);
      } finally {
        if (await temporaryDestination.exists()) {
          await temporaryDestination.delete();
        }
      }
      return RuleProviderFileDownload(
        path: destinationPath,
        length: info.size,
        sha256: digest,
        headers: Headers(),
      );
    } on Object {
      return null;
    }
  }

  Future<void> _writeCachedProvider(
    String root,
    Map<String, dynamic> definition,
    RuleProviderFileDownload download, {
    String kind = 'rule',
  }) async {
    final directory = Directory(root);
    await directory.create(recursive: true);
    final digest = download.sha256.toLowerCase();
    final identity = _providerIdentity(definition, kind: kind);
    final flightKey = '$root|$identity';
    final existingFlight = _providerCacheFlights[flightKey];
    if (existingFlight != null) {
      await existingFlight;
      return;
    }
    final completer = Completer<void>();
    _providerCacheFlights[flightKey] = completer.future;
    try {
      final source = File(p.join(root, '$digest.raw'));
      final sourceValid =
          await source.exists() && await _fileSHA256(source.path) == digest;
      if (!sourceValid) {
        if (await source.exists()) await source.delete();
        final temporarySource = File(
          '${source.path}.tmp.$pid.${DateTime.now().microsecondsSinceEpoch}.${_cacheNonce++}',
        );
        try {
          await File(download.path).copy(temporarySource.path);
          if (await _fileSHA256(temporarySource.path) != digest) {
            throw StateError('cache blob digest mismatch');
          }
          await temporarySource.rename(source.path);
        } finally {
          if (await temporarySource.exists()) await temporarySource.delete();
        }
      }
      final metadata = File(p.join(root, '$identity.json'));
      final temporary = File(
        '${metadata.path}.tmp.$pid.${DateTime.now().microsecondsSinceEpoch}.${_cacheNonce++}',
      );
      try {
        await temporary.writeAsString(
          jsonEncode({
            'identity': identity,
            'sha256': digest,
            'cached-at': DateTime.now().toUtc().toIso8601String(),
          }),
          flush: true,
        );
        if (await metadata.exists()) await metadata.delete();
        await temporary.rename(metadata.path);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
      completer.complete();
    } catch (error, stack) {
      if (!completer.isCompleted) completer.completeError(error, stack);
      Error.throwWithStackTrace(error, stack);
    } finally {
      if (identical(_providerCacheFlights[flightKey], completer.future)) {
        unawaited(_providerCacheFlights.remove(flightKey));
      }
    }
  }

  String _providerIdentity(
    Map<String, dynamic> definition, {
    String kind = 'rule',
  }) {
    final headers = _headers(definition['header']).entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    return _sha256String(
      jsonEncode({
        'version': 1,
        'kind': kind,
        'type': definition['type']?.toString() ?? '',
        'path': definition['path']?.toString() ?? '',
        'url': definition['url']?.toString() ?? '',
        'header-sha256': _sha256String(
          jsonEncode({for (final entry in headers) entry.key: entry.value}),
        ),
        'behavior': definition['behavior']?.toString() ?? 'domain',
        'format': definition['format']?.toString() ?? 'yaml',
        'size-limit': _sizeLimit(definition),
        'compiler': 'MRS-SC02',
      }),
    );
  }

  Future<List<T>> _mapWithLimit<T, E>(
    List<E> items,
    Future<T> Function(E item) operation,
  ) async {
    if (items.isEmpty) return <T>[];
    final results = List<T?>.filled(items.length, null);
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final index = next;
        if (index >= items.length) return;
        next = index + 1;
        results[index] = await operation(items[index]);
      }
    }

    final workers = List.generate(
      items.length < _providerDownloadConcurrency
          ? items.length
          : _providerDownloadConcurrency,
      (_) => worker(),
    );
    await Future.wait(workers);
    return results.cast<T>();
  }

  void _progress(
    RulePreparationPhase phase, {
    required String kind,
    required String name,
    required String path,
    Object? error,
  }) {
    _onProgress?.call(
      RulePreparationProgress(
        profileId: _activeProfileId,
        operationId: _operationId,
        phase: phase,
        kind: kind,
        name: name,
        path: path,
        error: error,
      ),
    );
  }

  static Future<RuleProviderFileDownload> _downloadWithSharedRequest(
    String url,
    Map<String, String> headers,
    int sizeLimit,
    String destinationPath,
    Duration timeout,
    CancelToken cancelToken,
  ) {
    return request.downloadRuleProviderToFile(
      url: url,
      headers: headers,
      sizeLimit: sizeLimit,
      destinationPath: destinationPath,
      timeout: timeout,
      cancelToken: cancelToken,
    );
  }
}

Future<(A, B)> _settleBoth<A, B>(Future<A> first, Future<B> second) async {
  A? firstValue;
  B? secondValue;
  Object? firstError;
  StackTrace? firstStack;
  await Future.wait<void>([
    first.then<void>((value) => firstValue = value).catchError((
      Object error,
      StackTrace stack,
    ) {
      firstError ??= error;
      firstStack ??= stack;
    }),
    second.then<void>((value) => secondValue = value).catchError((
      Object error,
      StackTrace stack,
    ) {
      firstError ??= error;
      firstStack ??= stack;
    }),
  ]);
  if (firstError != null) {
    Error.throwWithStackTrace(firstError!, firstStack!);
  }
  return (firstValue as A, secondValue as B);
}

class _PreparedProxyProvider {
  final String name;
  final Map<String, dynamic> definition;
  final String rawPath;
  final String rawSha256;
  const _PreparedProxyProvider(
    this.name,
    this.definition,
    this.rawPath,
    this.rawSha256,
  );
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
