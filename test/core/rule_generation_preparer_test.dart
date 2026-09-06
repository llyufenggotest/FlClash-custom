import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:fl_clash/common/request.dart';
import 'package:fl_clash/core/interface.dart';
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

  test(
    'provider size-limit cannot raise the 32 MiB hard ceiling',
    () async {
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
    },
  );

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
