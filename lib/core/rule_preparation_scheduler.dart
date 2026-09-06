import 'dart:async';

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

final rulePreparationScheduler = RulePreparationScheduler();
