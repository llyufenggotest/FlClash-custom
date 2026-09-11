import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fl_clash/common/request.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory home;

  setUp(() {
    home = Directory.systemTemp.createTempSync('rule-provider-request-');
  });

  tearDown(() {
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  test(
    'rule provider download requests a stream and preserves headers',
    () async {
      late RequestOptions captured;
      final adapter = _RuleProviderAdapter((options, _) {
        captured = options;
        return ResponseBody(
          Stream.value(Uint8List.fromList([1, 2, 3])),
          HttpStatus.ok,
          headers: {
            Headers.contentLengthHeader: ['3'],
            'x-result': ['kept'],
          },
        );
      });
      final client = Request(
        ruleProviderDioFactory: () => Dio()..httpClientAdapter = adapter,
      );

      final destination = p.join(home.path, 'rules.raw');
      final result = await client.downloadRuleProviderToFile(
        url: 'https://example.test/rules',
        headers: {'Authorization': 'Bearer token'},
        sizeLimit: 3,
        destinationPath: destination,
      );

      expect(captured.responseType, ResponseType.stream);
      expect(captured.headers['Authorization'], 'Bearer token');
      expect(await File(destination).readAsBytes(), [1, 2, 3]);
      expect(result.path, destination);
      expect(result.length, 3);
      expect(
        result.sha256,
        '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81',
      );
      expect(result.headers.value('x-result'), 'kept');
    },
  );

  test(
    'request enforces the 32 MiB hard limit even with a larger caller limit',
    () async {
      final adapter = _RuleProviderAdapter((_, _) {
        return ResponseBody(
          const Stream<Uint8List>.empty(),
          HttpStatus.ok,
          headers: {
            Headers.contentLengthHeader: ['33554433'],
          },
        );
      });
      final client = Request(
        ruleProviderDioFactory: () => Dio()..httpClientAdapter = adapter,
      );
      final destination = p.join(home.path, 'hard-limit.raw');

      await expectLater(
        client.downloadRuleProviderToFile(
          url: 'https://example.test/rules',
          headers: const {},
          sizeLimit: 64 * 1024 * 1024,
          destinationPath: destination,
        ),
        throwsA(isA<StateError>()),
      );

      expect(adapter.cancelled, isTrue);
      expect(File(destination).existsSync(), isFalse);
    },
  );

  test(
    'content length over the limit cancels and closes the adapter',
    () async {
      var listened = false;
      final adapter = _RuleProviderAdapter((_, _) {
        return ResponseBody(
          Stream<Uint8List>.multi((controller) {
            listened = true;
          }),
          HttpStatus.ok,
          headers: {
            Headers.contentLengthHeader: ['11'],
          },
        );
      });
      final client = Request(
        ruleProviderDioFactory: () => Dio()..httpClientAdapter = adapter,
      );

      await expectLater(
        client.downloadRuleProviderToFile(
          url: 'https://example.test/rules',
          headers: const {},
          sizeLimit: 10,
          destinationPath: p.join(home.path, 'content-length.raw'),
        ),
        throwsA(isA<StateError>()),
      );
      await Future<void>.delayed(Duration.zero);

      expect(listened, isTrue);
      expect(adapter.cancelled, isTrue);
      expect(adapter.closed, isTrue);
      expect(
        File(p.join(home.path, 'content-length.raw')).existsSync(),
        isFalse,
      );
    },
  );

  test(
    'chunked body is cancelled immediately when cumulative limit is exceeded',
    () async {
      var emitted = 0;
      late _RuleProviderAdapter adapter;
      adapter = _RuleProviderAdapter((_, _) {
        late StreamController<Uint8List> controller;
        controller = StreamController<Uint8List>(
          onListen: () async {
            for (final chunk in [
              Uint8List.fromList([1, 2]),
              Uint8List.fromList([3, 4]),
              Uint8List.fromList([5, 6]),
            ]) {
              if (adapter.cancelled) break;
              emitted++;
              controller.add(chunk);
              await Future<void>.delayed(Duration.zero);
            }
            await controller.close();
          },
        );
        return ResponseBody(controller.stream, HttpStatus.ok);
      });
      final client = Request(
        ruleProviderDioFactory: () => Dio()..httpClientAdapter = adapter,
      );

      await expectLater(
        client.downloadRuleProviderToFile(
          url: 'https://example.test/rules',
          headers: const {},
          sizeLimit: 3,
          destinationPath: p.join(home.path, 'chunked.raw'),
        ),
        throwsA(isA<StateError>()),
      );
      await Future<void>.delayed(Duration.zero);

      expect(adapter.cancelled, isTrue);
      expect(adapter.closed, isTrue);
      expect(emitted, lessThanOrEqualTo(3));
      expect(File(p.join(home.path, 'chunked.raw')).existsSync(), isFalse);
    },
  );
}

final class _RuleProviderAdapter implements HttpClientAdapter {
  final ResponseBody Function(
    RequestOptions options,
    Future<void>? cancelFuture,
  )
  response;
  bool cancelled = false;
  bool closed = false;

  _RuleProviderAdapter(this.response);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    cancelFuture?.then((_) => cancelled = true);
    return response(options, cancelFuture);
  }

  @override
  void close({bool force = false}) {
    closed = true;
  }
}
