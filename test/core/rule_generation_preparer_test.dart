import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:fl_clash/common/request.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/core/rule_generation_preparation.dart';
import 'package:fl_clash/core/rule_generation_preparer.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

class _MockCore extends Mock implements CoreHandlerInterface {}

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
          download: (url, headers, _, destinationPath) async {
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

  test('named proxy fails explicitly without downloading', () async {
    var downloads = 0;
    final preparer = RuleGenerationPreparer(
      core: core,
      homeDir: () async => home.path,
      download: (_, _, _, destinationPath) async {
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
            download: (_, headers, sizeLimit, destinationPath) async {
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
      download: (_, _, sizeLimit, destinationPath) async {
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

  test('reuses a verified rule cache across profiles', () async {
    var downloads = 0;
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
      return {'generation': generation, 'config-path': p.join(target, 'config.yaml')};
    });
    Future<RuleGenerationPreparation> prepare(int profileId) {
      return RuleGenerationPreparer(
        core: core,
        homeDir: () async => home.path,
        download: (_, _, _, destinationPath) async {
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
    await prepare(12);
    expect(downloads, 1);
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
        download: (_, _, _, destinationPath) => _writeDownload(
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
      throwsA(isA<StateError>().having(
        (error) => error.message,
        'message',
        contains('invalid rule reference'),
      )),
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

  test('downloads independent rule providers concurrently with a limit', () async {
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
    final future = RuleGenerationPreparer(
      core: core,
      homeDir: () async => home.path,
      download: (url, _, _, destinationPath) async {
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
    await Future<void>.delayed(Duration.zero);
    expect(started.length, 4);
    for (final release in releases.toList()) {
      release.complete();
    }
    await Future<void>.delayed(Duration.zero);
    expect(started.length, 5);
    releases.last.complete();
    await future;
  });

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
      final bytes = Uint8List.fromList('proxies:\n  - {name: x, type: direct}\n'.codeUnits);
      await File(target).parent.create(recursive: true);
      await File(target).writeAsBytes(bytes);
      return {'path': target, 'digest': sha256.convert(bytes).toString(), 'count': 1};
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
      final target = p.join(Directory(staging).parent.parent.path, 'generations', generation);
      await Directory(p.dirname(target)).create(recursive: true);
      await Directory(staging).rename(target);
      return {'generation': generation, 'config-path': p.join(target, 'config.yaml')};
    });
    final future = RuleGenerationPreparer(
      core: core,
      homeDir: () async => home.path,
      download: (_, _, _, destinationPath) async {
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
    await pumpEventQueue(times: 20);
    expect(releases.length, 4);
    for (final release in releases.toList()) {
      release.complete();
    }
    await pumpEventQueue(times: 20);
    expect(releases.length, 5);
    releases.last.complete();
    await future;
    expect(maximum, 4);
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
          download: (_, _, _, destinationPath) async => _writeDownload(
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
