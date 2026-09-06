import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/state.dart';
import 'package:flutter/cupertino.dart';

const _ruleProviderHardLimit = 32 * 1024 * 1024;

class RuleProviderFileDownload {
  final String path;
  final int length;
  final String sha256;
  final Headers headers;

  const RuleProviderFileDownload({
    required this.path,
    required this.length,
    required this.sha256,
    required this.headers,
  });
}

class Request {
  late final Dio dio;
  late final Dio _clashDio;
  final Dio Function()? _ruleProviderDioFactory;
  String? userAgent;

  Request({Dio Function()? ruleProviderDioFactory})
    : _ruleProviderDioFactory = ruleProviderDioFactory {
    dio = Dio(BaseOptions(headers: {'User-Agent': browserUa}));
    _clashDio = Dio();
    _clashDio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.badCertificateCallback =
            FlClashHttpOverrides.handleBadCertificate;
        client.findProxy = (Uri uri) {
          client.userAgent = globalState.ua;
          return FlClashHttpOverrides.handleFindProxy(uri);
        };
        return client;
      },
    );
  }

  Future<RuleProviderFileDownload> downloadRuleProviderToFile({
    required String url,
    required Map<String, String> headers,
    required int sizeLimit,
    required String destinationPath,
  }) async {
    if (sizeLimit <= 0) {
      throw ArgumentError.value(sizeLimit, 'sizeLimit', 'must be positive');
    }
    final effectiveLimit = sizeLimit > _ruleProviderHardLimit
        ? _ruleProviderHardLimit
        : sizeLimit;
    final dio =
        _ruleProviderDioFactory?.call() ??
        Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 10),
            receiveTimeout: const Duration(seconds: 30),
          ),
        );
    if (_ruleProviderDioFactory == null) {
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () => HttpClient()..findProxy = (_) => 'DIRECT',
      );
    }
    final cancelToken = CancelToken();
    final destination = File(destinationPath);
    IOSink? sink;
    var completed = false;
    Object? pendingError;
    StackTrace? pendingStack;
    RuleProviderFileDownload? result;
    try {
      final response = await dio.get<ResponseBody>(
        url,
        cancelToken: cancelToken,
        options: Options(headers: headers, responseType: ResponseType.stream),
      );
      final body = response.data;
      final contentLength = int.tryParse(
        response.headers.value(Headers.contentLengthHeader) ?? '',
      );
      if (contentLength != null && contentLength > effectiveLimit) {
        cancelToken.cancel('rule provider exceeds size-limit');
        throw StateError('rule provider exceeds size-limit');
      }

      await destination.parent.create(recursive: true);
      final outputSink = destination.openWrite(mode: FileMode.writeOnly);
      sink = outputSink;
      final digestSink = SingleValueSink<Digest>();
      final hashSink = sha256.startChunkedConversion(digestSink);
      var hashClosed = false;
      try {
        var received = 0;
        await for (final chunk
            in body?.stream ?? const Stream<Uint8List>.empty()) {
          received += chunk.length;
          if (received > effectiveLimit) {
            cancelToken.cancel('rule provider exceeds size-limit');
            throw StateError('rule provider exceeds size-limit');
          }
          outputSink.add(chunk);
          hashSink.add(chunk);
          await outputSink.flush();
        }
        hashSink.close();
        hashClosed = true;
        await outputSink.flush();
        await outputSink.close();
        sink = null;
        completed = true;
        result = RuleProviderFileDownload(
          path: destination.path,
          length: received,
          sha256: digestSink.value.toString(),
          headers: response.headers,
        );
      } finally {
        if (!hashClosed) hashSink.close();
      }
    } catch (error, stack) {
      pendingError = error;
      pendingStack = stack;
      final activeSink = sink;
      if (activeSink != null) {
        try {
          await activeSink.close();
        } catch (_) {}
        sink = null;
      }
    } finally {
      if (!completed && await destination.exists()) {
        try {
          await destination.delete();
        } catch (cleanupError, cleanupStack) {
          if (pendingError == null) {
            pendingError = cleanupError;
            pendingStack = cleanupStack;
          }
        }
      }
      dio.close(force: true);
    }
    if (pendingError != null) {
      Error.throwWithStackTrace(pendingError, pendingStack!);
    }
    if (result != null) return result;
    throw StateError('rule provider download did not complete');
  }

  Future<Response<Uint8List>> getFileResponseForUrl(String url) async {
    try {
      return await _clashDio
          .get<Uint8List>(
            url,
            options: Options(responseType: ResponseType.bytes),
          )
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      commonPrint.log('getFileResponseForUrl error ${e.toString()}');
      if (e is DioException) {
        if (e.type == DioExceptionType.unknown) {
          final detail = e.error?.toString().trim();
          if (detail != null && detail.isNotEmpty) {
            throw '${currentAppLocalizations.unknownNetworkError}\n$detail';
          }
          throw currentAppLocalizations.unknownNetworkError;
        } else if (e.type == DioExceptionType.badResponse) {
          final response = e.response;
          final statusCode = response?.statusCode ?? 0;
          final body = _extractResponseBody(response);
          final detail = body.isNotEmpty
              ? '[$statusCode]\n$body'
              : '[$statusCode]';
          throw '${currentAppLocalizations.networkException} $detail';
        }
        rethrow;
      }
      throw '${currentAppLocalizations.unknownNetworkError}\n$e';
    }
  }

  String _extractResponseBody(Response? response) {
    if (response == null) return '';
    final data = response.data;
    if (data == null) return '';
    if (data is Uint8List) {
      try {
        return utf8.decode(data).trim();
      } catch (_) {
        return '';
      }
    }
    return data.toString().trim();
  }

  Future<Response<String>> getTextResponseForUrl(String url) async {
    final response = await _clashDio
        .get<String>(url, options: Options(responseType: ResponseType.plain))
        .timeout(const Duration(seconds: 10));
    return response;
  }

  Future<MemoryImage?> getImage(String url) async {
    if (url.isEmpty) return null;
    final response = await dio
        .get<Uint8List>(url, options: Options(responseType: ResponseType.bytes))
        .timeout(const Duration(seconds: 10));
    final data = response.data;
    if (data == null) return null;
    return MemoryImage(data);
  }

  Future<Map<String, dynamic>?> checkForUpdate() async {
    try {
      final response = await dio
          .get(
            'https://api.github.com/repos/$repository/releases/latest',
            options: Options(responseType: ResponseType.json),
          )
          .timeout(const Duration(seconds: 10));
      final data = response.data as Map<String, dynamic>;
      final remoteVersion = data['tag_name'];
      final version = globalState.packageInfo.version;
      final hasUpdate =
          utils.compareVersions(remoteVersion.replaceAll('v', ''), version) > 0;
      if (!hasUpdate) return null;
      return data;
    } catch (e) {
      rethrow;
    }
  }

  final Map<String, IpInfo Function(Map<String, dynamic>)> _ipInfoSources = {
    'https://ipwho.is': IpInfo.fromIpWhoIsJson,
    'https://api.myip.com': IpInfo.fromMyIpJson,
    'https://ipapi.co/json': IpInfo.fromIpApiCoJson,
    'https://ident.me/json': IpInfo.fromIdentMeJson,
    'http://ip-api.com/json': IpInfo.fromIpAPIJson,
    'https://api.ip.sb/geoip': IpInfo.fromIpSbJson,
    'https://ipinfo.io/json': IpInfo.fromIpInfoIoJson,
  };

  Future<Result<IpInfo?>> checkIp({CancelToken? cancelToken}) async {
    var failureCount = 0;
    final token = cancelToken ?? CancelToken();
    final futures = _ipInfoSources.entries.map((source) async {
      final Completer<Result<IpInfo?>> completer = Completer();
      void handleFailRes() {
        if (!completer.isCompleted && failureCount == _ipInfoSources.length) {
          completer.complete(Result.success(null));
        }
      }

      final future = dio
          .get<Map<String, dynamic>>(
            source.key,
            cancelToken: token,
            options: Options(responseType: ResponseType.json),
          )
          .timeout(const Duration(seconds: 10));
      future
          .then((res) {
            if (res.statusCode == HttpStatus.ok && res.data != null) {
              completer.complete(Result.success(source.value(res.data!)));
              return;
            }
            commonPrint.log('checkIp data empty', logLevel: LogLevel.info);
            failureCount++;
            handleFailRes();
          })
          .catchError((e) {
            failureCount++;
            if (e is DioException && e.type == DioExceptionType.cancel) {
              completer.complete(Result.error('cancelled'));
              return;
            }
            commonPrint.log('checkIp error $e', logLevel: LogLevel.warning);
            handleFailRes();
          });
      return completer.future;
    });
    final res = await Future.any(futures);
    token.cancel();
    return res;
  }
}

final request = Request();
