import 'dart:async';

import 'package:fl_clash/core/rule_generation_preparer.dart';

/// Deduplicates only concurrent preparation. Durable readiness belongs to the
/// core manifest and must be queried before every later connection.
class RulePreparationScheduler {
  final Map<String, Future<String>> _inFlight = {};

  Future<String> prepare(String key, Future<String> Function() operation) {
    return _inFlight.putIfAbsent(key, () {
      final future = Future<String>.sync(operation);
      future.then<void>(
        (_) {
          _inFlight.remove(key);
        },
        onError: (Object _, StackTrace _) {
          _inFlight.remove(key);
        },
      );
      return future;
    });
  }

  void reset() => _inFlight.clear();
}

/// Coalesces an immutable generation together with its config path. Returning
/// only a status string loses the prepared path for every waiter except the
/// closure that happened to start the work.
class PreparedGenerationScheduler<T> {
  final Map<String, Future<T>> _inFlight = {};

  Future<T> prepare(String key, Future<T> Function() operation) {
    return _inFlight.putIfAbsent(key, () {
      final future = Future<T>.sync(operation);
      future.then<void>(
        (_) {
          _inFlight.remove(key);
        },
        onError: (Object _, StackTrace _) {
          _inFlight.remove(key);
        },
      );
      return future;
    });
  }

  void reset() => _inFlight.clear();
}

final rulePreparationScheduler = RulePreparationScheduler();
final preparedGenerationScheduler =
    PreparedGenerationScheduler<RuleGenerationPreparation>();
