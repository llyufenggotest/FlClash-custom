import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:fl_clash/common/request.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/core/rule_generation_preparation.dart';
import 'package:fl_clash/core/rule_generation_preparer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

class _MockCore extends Mock implements CoreHandlerInterface {}

Future<void> _waitUntil(
  bool Function() condition, {
  String reason = 'condition did not become true',
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail(reason);
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void _completeAll(List<Completer<void>> releases) {
  for (final release in releases) {
    if (!release.isCompleted) release.complete();
  }
}

void main() {
  late Directory home;
  late _MockCore core;

  setUp(() {
    home = Directory.systemTemp.createTempSync('rule-generation-test-');
    core = _MockCore();
    when(
      () => core.getPreparedRuleGeneration(
        profileId: any(named: 'profileId'),
        fingerprint: any(named: 'fingerprint'),
      ),
    ).thenAnswer((_) async => {});
    when(
      () => core.validateStagedConfigAtPath(
        profileId: any(named: 'profileId'),
        stagingPath: any(named: 'stagingPath'),
        candidateConfigPath: any(named: 'candidateConfigPath'),
      ),
    ).thenAnswer((_) async => '');
    when(
      () => core.validateCandidateConfigAtPath(any()),
    ).thenAnswer((_) async => '');
    when(
      () => core.setProfileSwitchProbeBarrier(
        token: any(named: 'token'),
        suspended: any(named: 'suspended'),
      ),
    ).thenAnswer((_) async => true);
  });

  tearDown(() => home.deleteSync(recursive: true));

  test('downloads with headers and publishes file-only final YAML', () async {
    String? downloadedUrl;
    Map<String, String>? downloadedHeaders;
    when(
      () => core.prewarmRuleProvider(
        name: 'ads',
        definition: any(named: 'definition'),
        targetPath: any(named: 'targetPath'),
      ),
    ).thenAnswer((invocation) async {
      final target = invocation.namedArguments[#targetPath] as String;
      await File('$target.mrs').writeAsBytes([1, 2, 3]);
      return {'sidecar': '$target.mrs', 'count': 1};
    });
    when(
      () => core.publishRuleGeneration(
        profileId: 3,
        fingerprint: any(named: 'fingerprint'),
        generation: any(named: 'generation'),
        stagingPath: any(named: 'stagingPath'),
        configPath: any(named: 'configPath'),
        artifacts: any(named: 'artifacts'),
      ),
    ).thenAnswer((invocation) async {
      final staging = invocation.namedArguments[#stagingPath] as String;
      final generation = invocation.namedArguments[#generation] as String;
      final profileRoot = Directory(staging).parent.parent.path;
      final target =
          '$profileRoot${Platform.pathSeparator}generations${Platform.pathSeparator}$generation';
      await Directory(
        '$profileRoot${Platform.pathSeparator}generations',
      ).create(recursive: true);
      await Directory(staging).rename(target);
      return {
        'generation': generation,
        'config-path': '$target${Platform.pathSeparator}config.yaml',
      };
    });

    final result =
        await RuleGenerationPreparer(
          core: core,
          homeDir: () async => home.path,
          download: (url, headers, _, destinationPath, _, _) async {
            downloadedUrl = url;
            downloadedHeaders = headers;
            final bytes = Uint8List.fromList('example.com\n'.codeUnits);
            await File(destinationPath).parent.create(recursive: true);
            await File(destinationPath).writeAsBytes(bytes);
            return RuleProviderFileDownload(
              path: destinationPath,
              length: bytes.length,
              sha256:
                  '391196688aa55d3321deffa736f8d103b4813470952b748e9c2c9deb17fa60f5',
              headers: Headers(),
            );
          },
        ).prepare(
          profileId: 3,
          config: '''
rule-providers:
  ads:
    type: http
    url: https://example.test/ads
    proxy: DIRECT
    header:
      Authorization: [Bearer token]
    behavior: domain
    format: text
rules:
  - RULE-SET,ads,DIRECT
''',
        );

    expect(downloadedUrl, 'https://example.test/ads');
    expect(downloadedHeaders, {'Authorization': 'Bearer token'});
    final yaml = loadYaml(result.config) as YamlMap;
    final provider = (yaml['rule-providers'] as YamlMap)['ads'] as YamlMap;
    expect(provider['type'], 'file');
    expect(
      provider['path'],
      contains('/generations/'.replaceAll('/', Platform.pathSeparator)),
    );
    for (final key in ['url', 'proxy', 'interval', 'size-limit']) {
      expect(provider.containsKey(key), isFalse, reason: key);
    }
    expect(provider['header']['Authorization'], ['Bearer token']);
    expect((yaml['rules'] as YamlList).single, 'RULE-SET,ads,DIRECT');
  });

  test(
    'retries only transient Dio failures with deterministic backoff',
    () async {
      var attempts = 0;
      final sleeps = <Duration>[];
      var now = DateTime.utc(2026);
      when(
        () => core.publishRuleGeneration(
          profileId: 15,
          fingerprint: any(named: 'fingerprint'),
          generation: any(named: 'generation'),
          stagingPath: any(named: 'stagingPath'),
          configPath: any(named: 'configPath'),
          artifacts: any(named: 'artifacts'),
        ),
      ).thenAnswer((invocation) async {
        final staging = invocation.namedArguments[#stagingPath] as String;
        final generation = invocation.namedArguments[#generation] as String;
        final target = p.join(
          Directory(staging).parent.parent.path,
          'generations',
          generation,
        );
        await Directory(p.dirname(target)).create(recursive: true);
        await Directory(staging).rename(target);
        return {
          'generation': generation,
          'config-path': p.join(target, 'config.yaml'),
        };
      });

      await RuleGenerationPreparer(
        core: core,
        homeDir: () async => home.path,
        clock: () => now,
        sleeper: (duration) async {
          sleeps.add(duration);
          now = now.add(duration);
        },
        retryJitter: () => 0,
        download: (_, _, _, destinationPath, _, _) async {
          attempts++;
          if (attempts < 3) {
            throw DioException(
              requestOptions: RequestOptions(path: '/ads'),
              type: attempts == 1
                  ? DioExceptionType.receiveTimeout
                  : DioExceptionType.connectionError,
            );
          }
          return _writeDownload(
            destinationPath,
            Uint8List.fromList('payload:\n  - example.com\n'.codeUnits),
          );
        },
      ).prepare(
        profileId: 15,
        config: '''
rule-providers:
  ads: {type: http, url: https://example.test/ads, behavior: classical}
rules: [RULE-SET,ads,DIRECT]
''',
      );

      expect(attempts, 3);
      expect(sleeps, const [
        Duration(milliseconds: 250),
        Duration(milliseconds: 500),
      ]);
    },
  );

  test(
    'does not retry non-transient failures and retains provider name',
    () async {
      for (final error in <Exception>[
        DioException(
          requestOptions: RequestOptions(path: '/ads'),
          type: DioExceptionType.badResponse,
          response: Response<void>(
            requestOptions: RequestOptions(path: '/ads'),
            statusCode: 404,
          ),
        ),
        const FormatException('bad payload'),
      ]) {
        var attempts = 0;
        final sleeps = <Duration>[];
        final profileId = error is FormatException ? 18 : 16;
        await expectLater(
          RuleGenerationPreparer(
            core: core,
            homeDir: () async => home.path,
            sleeper: (duration) async => sleeps.add(duration),
            retryJitter: () => 0,
            download: (_, _, _, _, _, _) async {
              attempts++;
              throw error;
            },
          ).prepare(
            profileId: profileId,
            config: '''
rule-providers:
  ads: {type: http, url: https://example.test/ads, behavior: classical}
rules: [RULE-SET,ads,DIRECT]
''',
          ),
          throwsA(
            isA<StateError>().having(
              (value) => value.message,
              'message',
              allOf(
                contains('rule provider "ads" download failed'),
                contains('after 1 attempt'),
              ),
            ),
          ),
        );
        expect(attempts, 1);
        expect(sleeps, isEmpty);
      }
    },
  );

  test('retries 429 but stops at the explicit attempt bound', () async {
    var attempts = 0;
    final sleeps = <Duration>[];
    await expectLater(
      RuleGenerationPreparer(
        core: core,
        homeDir: () async => home.path,
        sleeper: (duration) async => sleeps.add(duration),
        retryJitter: () => 0,
        download: (_, _, _, _, _, _) async {
          attempts++;
          final options = RequestOptions(path: '/limited');
          throw DioException(
            requestOptions: options,
            type: DioExceptionType.badResponse,
            response: Response<void>(requestOptions: options, statusCode: 429),
          );
        },
      ).prepare(
        profileId: 17,
        config: '''
rule-providers:
  limited: {type: http, url: https://example.test/limited, behavior: classical}
rules: [RULE-SET,limited,DIRECT]
''',
      ),
      throwsA(
        isA<StateError>().having(
          (value) => value.message,
          'message',
          allOf(contains('limited'), contains('after 3 attempts')),
        ),
      ),
    );
    expect(attempts, 3);
    expect(sleeps, hasLength(2));
    expect(
      sleeps.fold<Duration>(Duration.zero, (total, delay) => total + delay),
      lessThanOrEqualTo(const Duration(seconds: 2)),
    );
  });

  test('passes the remaining total deadline into each retry', () async {
    var now = DateTime.utc(2026);
    final timeouts = <Duration>[];
    var attempts = 0;
    await expectLater(
      RuleGenerationPreparer(
        core: core,
        homeDir: () async => home.path,
        clock: () => now,
        downloadDeadline: const Duration(seconds: 45),
        downloadAttemptCap: const Duration(seconds: 30),
        retryJitter: () => 0,
        sleeper: (delay) async => now = now.add(delay),
        download: (_, _, _, _, timeout, _) async {
          timeouts.add(timeout);
          attempts++;
          now = now.add(const Duration(seconds: 25));
          throw DioException(
            requestOptions: RequestOptions(path: '/slow'),
            type: DioExceptionType.receiveTimeout,
          );
        },
      ).prepare(
        profileId: 19,
        config: '''
rule-providers:
  slow: {type: http, url: https://example.test/slow, behavior: classical}
rules: []
''',
      ),
      throwsA(isA<StateError>()),
    );

    expect(attempts, 2);
    expect(timeouts, const [
      Duration(seconds: 30),
      Duration(milliseconds: 19750),
    ]);
  });

  test('named proxy fails explicitly without downloading', () async {
    var downloads = 0;
    final preparer = RuleGenerationPreparer(
      core: core,
      homeDir: () async => home.path,
      download: (_, _, _, destinationPath, _, _) async {
        downloads++;
        return _writeDownload(destinationPath, Uint8List(0));
      },
    );
    await expectLater(
      preparer.prepare(
        profileId: 4,
        config: '''
rule-providers:
  ads:
    type: http
    url: https://example.test/ads
    proxy: select
    behavior: domain
rules: [RULE-SET,ads,DIRECT]
''',
      ),
      throwsA(
        isA<UnsupportedError>().having(
          (error) => error.message,
          'message',
          contains('proxy "select"'),
        ),
      ),
    );
    expect(downloads, 0);
  });

  test(
    'small classical provider is published raw-only with headers kept',
    () async {
      Map<String, dynamic>? publishedArtifact;
      when(
        () => core.publishRuleGeneration(
          profileId: 5,
          fingerprint: any(named: 'fingerprint'),
          generation: any(named: 'generation'),
          stagingPath: any(named: 'stagingPath'),
          configPath: any(named: 'configPath'),
          artifacts: any(named: 'artifacts'),
        ),
      ).thenAnswer((invocation) async {
        final staging = invocation.namedArguments[#stagingPath] as String;
        final generation = invocation.namedArguments[#generation] as String;
        final artifacts =
            invocation.namedArguments[#artifacts] as List<Map<String, dynamic>>;
        publishedArtifact = artifacts.single;
        final profileRoot = Directory(staging).parent.parent.path;
        final target = p.join(profileRoot, 'generations', generation);
        await Directory(p.dirname(target)).create(recursive: true);
        await Directory(staging).rename(target);
        return {
          'generation': generation,
          'config-path': p.join(target, 'config.yaml'),
        };
      });
      final raw = List.generate(
        10000,
        (index) => 'DOMAIN,host$index.example',
      ).join('\n');

      final result =
          await RuleGenerationPreparer(
            core: core,
            homeDir: () async => home.path,
            download: (_, headers, sizeLimit, destinationPath, _, _) async {
              expect(headers, {'Authorization': 'Bearer token'});
              expect(sizeLimit, 32 * 1024 * 1024);
              return _writeDownload(
                destinationPath,
                Uint8List.fromList(raw.codeUnits),
              );
            },
          ).prepare(
            profileId: 5,
            config: '''
rule-providers:
  legacy:
    type: http
    url: https://example.test/legacy
    proxy: DIRECT
    header:
      Authorization: Bearer token
    behavior: classical
    format: text
rules: [RULE-SET,legacy,DIRECT]
''',
          );

      verifyNever(
        () => core.prewarmRuleProvider(
          name: any(named: 'name'),
          definition: any(named: 'definition'),
          targetPath: any(named: 'targetPath'),
        ),
      );
      expect(publishedArtifact, isNotNull);
      expect(publishedArtifact!.containsKey('mrs-path'), isFalse);
      expect(publishedArtifact!.containsKey('mrs-sha256'), isFalse);
      final yaml = loadYaml(result.config) as YamlMap;
      final provider = (yaml['rule-providers'] as YamlMap)['legacy'] as YamlMap;
      expect(provider['type'], 'file');
      expect(provider['behavior'], 'classical');
      expect(provider['header']['Authorization'], 'Bearer token');
      expect(provider.containsKey('url'), isFalse);
      expect(provider.containsKey('proxy'), isFalse);
    },
  );

  test('provider size-limit cannot raise the 32 MiB hard ceiling', () async {
    var observedLimit = 0;
    when(
      () => core.prewarmRuleProvider(
        name: any(named: 'name'),
        definition: any(named: 'definition'),
        targetPath: any(named: 'targetPath'),
      ),
    ).thenAnswer((invocation) async {
      final target = invocation.namedArguments[#targetPath] as String;
      await File('$target.mrs').writeAsBytes([1, 2, 3]);
      return {'sidecar': '$target.mrs', 'count': 1};
    });
    when(
      () => core.publishRuleGeneration(
        profileId: 7,
        fingerprint: any(named: 'fingerprint'),
        generation: any(named: 'generation'),
        stagingPath: any(named: 'stagingPath'),
        configPath: any(named: 'configPath'),
        artifacts: any(named: 'artifacts'),
      ),
    ).thenAnswer((invocation) async {
      final staging = invocation.namedArguments[#stagingPath] as String;
      final generation = invocation.namedArguments[#generation] as String;
      final profileRoot = Directory(staging).parent.parent.path;
      final target = p.join(profileRoot, 'generations', generation);
      await Directory(p.dirname(target)).create(recursive: true);
      await Directory(staging).rename(target);
      return {
        'generation': generation,
        'config-path': p.join(target, 'config.yaml'),
      };
    });

    await RuleGenerationPreparer(
      core: core,
      homeDir: () async => home.path,
      download: (_, _, sizeLimit, destinationPath, _, _) async {
        observedLimit = sizeLimit;
        return _writeDownload(destinationPath, Uint8List.fromList([1]));
      },
    ).prepare(
      profileId: 7,
      config: '''
rule-providers:
  ads:
    type: http
    url: https://example.test/ads
    proxy: DIRECT
    size-limit: 67108864
    behavior: domain
    format: text
rules: [RULE-SET,ads,DIRECT]
''',
    );

    expect(observedLimit, 32 * 1024 * 1024);
  });

  test('reuses verified rule and MRS caches across profiles', () async {
    var downloads = 0;
    var compilations = 0;
    final secondProgress = <RulePreparationProgress>[];
    when(
      () => core.publishRuleGeneration(
        profileId: any(named: 'profileId'),
        fingerprint: any(named: 'fingerprint'),
        generation: any(named: 'generation'),
        stagingPath: any(named: 'stagingPath'),
        configPath: any(named: 'configPath'),
        artifacts: any(named: 'artifacts'),
      ),
    ).thenAnswer((invocation) async {
      final staging = invocation.namedArguments[#stagingPath] as String;
      final generation = invocation.namedArguments[#generation] as String;
      final root = Directory(staging).parent.parent.path;
      final target = p.join(root, 'generations', generation);
      await Directory(p.dirname(target)).create(recursive: true);
      await Directory(staging).rename(target);
      return {
        'generation': generation,
        'config-path': p.join(target, 'config.yaml'),
      };
    });
    when(
      () => core.prewarmRuleProvider(
        name: any(named: 'name'),
        definition: any(named: 'definition'),
        targetPath: any(named: 'targetPath'),
      ),
    ).thenAnswer((invocation) async {
      final target = invocation.namedArguments[#targetPath] as String;
      if (!await File('$target.mrs').exists()) {
        compilations++;
        await File('$target.mrs').writeAsBytes([1, 2, 3]);
      }
      return {'sidecar': '$target.mrs', 'count': 1};
    });
    Future<RuleGenerationPreparation> prepare(
      int profileId, {
      void Function(RulePreparationProgress)? onProgress,
    }) {
      return RuleGenerationPreparer(
        core: core,
        homeDir: () async => home.path,
        onProgress: onProgress,
        download: (_, _, _, destinationPath, _, _) async {
          downloads++;
          return _writeDownload(
            destinationPath,
            Uint8List.fromList('example.com\n'.codeUnits),
          );
        },
      ).prepare(
        profileId: profileId,
        config: '''
rule-providers:
  ads: {type: http, url: https://example.test/ads, behavior: domain, format: text}
rules: [RULE-SET,ads,DIRECT]
''',
      );
    }

    await prepare(11);
    await prepare(12, onProgress: secondProgress.add);
    expect(downloads, 1);
    expect(compilations, 1);
    expect(
      secondProgress.map((event) => event.phase),
      isNot(
        anyOf(
          contains(RulePreparationPhase.downloading),
          contains(RulePreparationPhase.compiling),
        ),
      ),
    );
  });

  test('rejects invalid final config before publishing', () async {
    when(
      () => core.validateStagedConfigAtPath(
        profileId: any(named: 'profileId'),
        stagingPath: any(named: 'stagingPath'),
        candidateConfigPath: any(named: 'candidateConfigPath'),
      ),
    ).thenAnswer((_) async => 'invalid rule reference');
    await expectLater(
      RuleGenerationPreparer(
        core: core,
        homeDir: () async => home.path,
        download: (_, _, _, destinationPath, _, _) => _writeDownload(
          destinationPath,
          Uint8List.fromList('payload:\n  - example.com\n'.codeUnits),
        ),
      ).prepare(
        profileId: 13,
        config: '''
rule-providers:
  ads: {type: http, url: https://example.test/ads, behavior: classical}
rules: [RULE-SET,ads,DIRECT]
''',
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('invalid rule reference'),
        ),
      ),
    );
    verifyNever(
      () => core.publishRuleGeneration(
        profileId: any(named: 'profileId'),
        fingerprint: any(named: 'fingerprint'),
        generation: any(named: 'generation'),
        stagingPath: any(named: 'stagingPath'),
        configPath: any(named: 'configPath'),
        artifacts: any(named: 'artifacts'),
      ),
    );
  });

  test(
    'downloads independent rule providers concurrently with a limit',
    () async {
      final started = <String>[];
      final releases = <Completer<void>>[];
      when(
        () => core.publishRuleGeneration(
          profileId: 8,
          fingerprint: any(named: 'fingerprint'),
          generation: any(named: 'generation'),
          stagingPath: any(named: 'stagingPath'),
          configPath: any(named: 'configPath'),
          artifacts: any(named: 'artifacts'),
        ),
      ).thenAnswer((invocation) async {
        final staging = invocation.namedArguments[#stagingPath] as String;
        final generation = invocation.namedArguments[#generation] as String;
        final root = Directory(staging).parent.parent.path;
        final target = p.join(root, 'generations', generation);
        await Directory(p.dirname(target)).create(recursive: true);
        await Directory(staging).rename(target);
        return {
          'generation': generation,
          'config-path': p.join(target, 'config.yaml'),
        };
      });
      final future =
          RuleGenerationPreparer(
            core: core,
            homeDir: () async => home.path,
            download: (url, _, _, destinationPath, _, _) async {
              started.add(url);
              final release = Completer<void>();
              releases.add(release);
              await release.future;
              return _writeDownload(
                destinationPath,
                Uint8List.fromList('payload:\n  - example.com\n'.codeUnits),
              );
            },
          ).prepare(
            profileId: 8,
            config: '''
rule-providers:
  a: {type: http, url: https://example.test/a, behavior: classical}
  b: {type: http, url: https://example.test/b, behavior: classical}
  c: {type: http, url: https://example.test/c, behavior: classical}
  d: {type: http, url: https://example.test/d, behavior: classical}
  e: {type: http, url: https://example.test/e, behavior: classical}
rules: []
''',
          );
      try {
        await _waitUntil(
          () => started.length == 4,
          reason: 'the first four provider downloads did not start',
        );
        expect(started.length, 4);
        _completeAll(releases.toList());
        await _waitUntil(
          () => started.length == 5,
          reason: 'the queued provider download did not start',
        );
        expect(started.length, 5);
        releases.last.complete();
        await future.timeout(const Duration(seconds: 2));
      } finally {
        _completeAll(releases);
      }
    },
  );

  test('shares the limit across proxy and rule providers', () async {
    var active = 0;
    var maximum = 0;
    final releases = <Completer<void>>[];
    Future<void> block() async {
      active++;
      if (active > maximum) maximum = active;
      final release = Completer<void>();
      releases.add(release);
      await release.future;
      active--;
    }

    when(
      () => core.prewarmProxyProvider(
        name: any(named: 'name'),
        definition: any(named: 'definition'),
        targetPath: any(named: 'targetPath'),
        timeoutMilliseconds: any(named: 'timeoutMilliseconds'),
      ),
    ).thenAnswer((invocation) async {
      final target = invocation.namedArguments[#targetPath] as String;
      await block();
      final bytes = Uint8List.fromList(
        'proxies:\n  - {name: x, type: direct}\n'.codeUnits,
      );
      await File(target).parent.create(recursive: true);
      await File(target).writeAsBytes(bytes);
      return {
        'path': target,
        'digest': sha256.convert(bytes).toString(),
        'count': 1,
      };
    });
    when(
      () => core.publishRuleGeneration(
        profileId: any(named: 'profileId'),
        fingerprint: any(named: 'fingerprint'),
        generation: any(named: 'generation'),
        stagingPath: any(named: 'stagingPath'),
        configPath: any(named: 'configPath'),
        artifacts: any(named: 'artifacts'),
      ),
    ).thenAnswer((invocation) async {
      final staging = invocation.namedArguments[#stagingPath] as String;
      final generation = invocation.namedArguments[#generation] as String;
      final target = p.join(
        Directory(staging).parent.parent.path,
        'generations',
        generation,
      );
      await Directory(p.dirname(target)).create(recursive: true);
      await Directory(staging).rename(target);
      return {
        'generation': generation,
        'config-path': p.join(target, 'config.yaml'),
      };
    });
    final future =
        RuleGenerationPreparer(
          core: core,
          homeDir: () async => home.path,
          download: (_, _, _, destinationPath, _, _) async {
            await block();
            return _writeDownload(
              destinationPath,
              Uint8List.fromList('payload:\n  - example.com\n'.codeUnits),
            );
          },
        ).prepare(
          profileId: 14,
          config: '''
proxy-providers:
  p1: {type: http, url: https://example.test/p1}
  p2: {type: http, url: https://example.test/p2}
  p3: {type: http, url: https://example.test/p3}
rule-providers:
  r1: {type: http, url: https://example.test/r1, behavior: classical}
  r2: {type: http, url: https://example.test/r2, behavior: classical}
rules: []
''',
        );
    try {
      await _waitUntil(
        () => releases.length == 4,
        reason: 'the shared pool did not fill all four slots',
      );
      expect(releases.length, 4);
      _completeAll(releases.toList());
      await _waitUntil(
        () => releases.length == 5,
        reason: 'the fifth provider did not acquire a released slot',
      );
      expect(releases.length, 5);
      releases.last.complete();
      await future.timeout(const Duration(seconds: 2));
      expect(maximum, 4);
    } finally {
      _completeAll(releases);
    }
  });

  test(
    'timed-out operation releases slots and cannot starve the next operation',
    () async {
      when(
        () => core.publishRuleGeneration(
          profileId: 22,
          fingerprint: any(named: 'fingerprint'),
          generation: any(named: 'generation'),
          stagingPath: any(named: 'stagingPath'),
          configPath: any(named: 'configPath'),
          artifacts: any(named: 'artifacts'),
        ),
      ).thenAnswer((invocation) async {
        final staging = invocation.namedArguments[#stagingPath] as String;
        final generation = invocation.namedArguments[#generation] as String;
        final target = p.join(
          Directory(staging).parent.parent.path,
          'generations',
          generation,
        );
        await Directory(p.dirname(target)).create(recursive: true);
        await Directory(staging).rename(target);
        return {
          'generation': generation,
          'config-path': p.join(target, 'config.yaml'),
        };
      });

      final firstStarted = <String>[];
      final cancelled = <CancelToken>[];
      final first =
          RuleGenerationPreparer(
            core: core,
            homeDir: () async => home.path,
            downloadDeadline: const Duration(milliseconds: 40),
            downloadAttemptCap: const Duration(milliseconds: 10),
            retryJitter: () => 0,
            download: (url, _, _, _, _, cancelToken) {
              firstStarted.add(url);
              cancelled.add(cancelToken);
              return Completer<RuleProviderFileDownload>().future;
            },
          ).prepare(
            profileId: 21,
            config: '''
rule-providers:
  a: {type: http, url: https://example.test/a, behavior: classical}
  b: {type: http, url: https://example.test/b, behavior: classical}
  c: {type: http, url: https://example.test/c, behavior: classical}
  d: {type: http, url: https://example.test/d, behavior: classical}
  e: {type: http, url: https://example.test/e, behavior: classical}
rules: []
''',
          );
      final firstFailure = expectLater(first, throwsA(isA<StateError>()));
      await _waitUntil(
        () => firstStarted.length == 4,
        reason: 'the timed-out operation did not occupy the pool',
      );
      expect(firstStarted, hasLength(4));

      final second =
          RuleGenerationPreparer(
            core: core,
            homeDir: () async => home.path,
            download: (_, _, _, destinationPath, _, _) => _writeDownload(
              destinationPath,
              Uint8List.fromList('payload:\n  - second.example\n'.codeUnits),
            ),
          ).prepare(
            profileId: 22,
            config: '''
rule-providers:
  next: {type: http, url: https://example.test/next, behavior: classical}
rules: []
''',
          );
      await expectLater(second.timeout(const Duration(seconds: 1)), completes);

      await firstFailure;
      expect(firstStarted, hasLength(4));
      expect(cancelled, isNotEmpty);
      expect(cancelled.every((token) => token.isCancelled), isTrue);
    },
  );

  test('retries transient proxy prewarm failures and cleans staging', () async {
    var attempts = 0;
    final timeouts = <int>[];
    when(
      () => core.prewarmProxyProvider(
        name: 'remote',
        definition: any(named: 'definition'),
        targetPath: any(named: 'targetPath'),
        timeoutMilliseconds: any(named: 'timeoutMilliseconds'),
      ),
    ).thenAnswer((invocation) async {
      attempts++;
      final target = invocation.namedArguments[#targetPath] as String;
      timeouts.add(invocation.namedArguments[#timeoutMilliseconds] as int);
      if (attempts < 3) {
        await File(target).parent.create(recursive: true);
        await File(target).writeAsString('partial-$attempts');
        await File('$target.leaked.tmp').writeAsString('partial');
        throw const CoreMethodException(
          code: 'core_error',
          message: 'Get "https://example.test": connection reset by peer',
        );
      }
      expect(await File(target).exists(), isFalse);
      final priorAttempt = target.replaceFirst('attempt.3', 'attempt.2');
      expect(await File(priorAttempt).exists(), isFalse);
      expect(await File('$priorAttempt.leaked.tmp').exists(), isFalse);
      return _writeProxyResult(target);
    });
    _stubPublish(core);

    await RuleGenerationPreparer(
      core: core,
      homeDir: () async => home.path,
      sleeper: (_) async {},
      retryJitter: () => 0,
    ).prepare(
      profileId: 23,
      config: '''
proxy-providers:
  remote: {type: http, url: https://example.test/proxies}
rules: []
''',
    );

    expect(attempts, 3);
    expect(timeouts, everyElement(const Duration(seconds: 20).inMilliseconds));
  });

  test('does not retry non-transient proxy prewarm failures', () async {
    var attempts = 0;
    when(
      () => core.prewarmProxyProvider(
        name: any(named: 'name'),
        definition: any(named: 'definition'),
        targetPath: any(named: 'targetPath'),
        timeoutMilliseconds: any(named: 'timeoutMilliseconds'),
      ),
    ).thenAnswer((_) async {
      attempts++;
      throw const CoreMethodException(
        code: 'core_error',
        message: '400 Bad Request',
      );
    });

    await expectLater(
      RuleGenerationPreparer(
        core: core,
        homeDir: () async => home.path,
        sleeper: (_) async {},
        retryJitter: () => 0,
      ).prepare(
        profileId: 24,
        config: '''
proxy-providers:
  invalid: {type: http, url: https://example.test/proxies}
rules: []
''',
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          allOf(contains('invalid'), contains('after 1 attempt')),
        ),
      ),
    );
    expect(attempts, 1);
  });

  test('proxy prewarm retries share one total deadline', () async {
    var now = DateTime.utc(2026);
    final timeouts = <int>[];
    when(
      () => core.prewarmProxyProvider(
        name: any(named: 'name'),
        definition: any(named: 'definition'),
        targetPath: any(named: 'targetPath'),
        timeoutMilliseconds: any(named: 'timeoutMilliseconds'),
      ),
    ).thenAnswer((invocation) async {
      timeouts.add(invocation.namedArguments[#timeoutMilliseconds] as int);
      now = now.add(const Duration(seconds: 25));
      throw const CoreMethodException(
        code: 'core_error',
        message: 'context deadline exceeded',
      );
    });

    await expectLater(
      RuleGenerationPreparer(
        core: core,
        homeDir: () async => home.path,
        clock: () => now,
        downloadDeadline: const Duration(seconds: 45),
        downloadAttemptCap: const Duration(seconds: 30),
        sleeper: (delay) async => now = now.add(delay),
        retryJitter: () => 0,
      ).prepare(
        profileId: 25,
        config: '''
proxy-providers:
  slow: {type: http, url: https://example.test/proxies}
rules: []
''',
      ),
      throwsA(isA<StateError>()),
    );

    expect(timeouts, const [30000, 19750]);
  });

  test(
    'classical provider over 10000 rules is rejected before publish',
    () async {
      final raw = List.generate(
        10001,
        (index) => 'DOMAIN,host$index.example',
      ).join('\n');

      await expectLater(
        RuleGenerationPreparer(
          core: core,
          homeDir: () async => home.path,
          download: (_, _, _, destinationPath, _, _) async => _writeDownload(
            destinationPath,
            Uint8List.fromList(raw.codeUnits),
          ),
        ).prepare(
          profileId: 6,
          config: '''
rule-providers:
  legacy:
    type: http
    url: https://example.test/legacy
    behavior: classical
    format: text
rules: [RULE-SET,legacy,DIRECT]
''',
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('exceeds classical rule limit of 10000'),
          ),
        ),
      );
      verifyNever(
        () => core.publishRuleGeneration(
          profileId: any(named: 'profileId'),
          fingerprint: any(named: 'fingerprint'),
          generation: any(named: 'generation'),
          stagingPath: any(named: 'stagingPath'),
          configPath: any(named: 'configPath'),
          artifacts: any(named: 'artifacts'),
        ),
      );
    },
  );
}

Future<Map<String, dynamic>> _writeProxyResult(String path) async {
  final bytes = Uint8List.fromList(
    'proxies:\n  - {name: x, type: direct}\n'.codeUnits,
  );
  await File(path).parent.create(recursive: true);
  await File(path).writeAsBytes(bytes);
  return {'path': path, 'digest': sha256.convert(bytes).toString(), 'count': 1};
}

void _stubPublish(_MockCore core) {
  when(
    () => core.publishRuleGeneration(
      profileId: any(named: 'profileId'),
      fingerprint: any(named: 'fingerprint'),
      generation: any(named: 'generation'),
      stagingPath: any(named: 'stagingPath'),
      configPath: any(named: 'configPath'),
      artifacts: any(named: 'artifacts'),
    ),
  ).thenAnswer((invocation) async {
    final staging = invocation.namedArguments[#stagingPath] as String;
    final generation = invocation.namedArguments[#generation] as String;
    final target = p.join(
      Directory(staging).parent.parent.path,
      'generations',
      generation,
    );
    await Directory(p.dirname(target)).create(recursive: true);
    await Directory(staging).rename(target);
    return {
      'generation': generation,
      'config-path': p.join(target, 'config.yaml'),
    };
  });
}

Future<RuleProviderFileDownload> _writeDownload(
  String path,
  Uint8List bytes,
) async {
  await File(path).parent.create(recursive: true);
  await File(path).writeAsBytes(bytes);
  return RuleProviderFileDownload(
    path: path,
    length: bytes.length,
    sha256: sha256.convert(bytes).toString(),
    headers: Headers(),
  );
}
