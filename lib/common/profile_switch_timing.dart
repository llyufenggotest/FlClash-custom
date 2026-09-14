typedef ProfileSwitchTimingSink =
    void Function(String phase, Duration phaseElapsed, Duration totalElapsed);

/// Emits monotonic phase durations without coupling switch code to a metrics SDK.
///
/// The injected clock keeps ordering and delta behavior deterministic in tests.
class ProfileSwitchPhaseTimer {
  ProfileSwitchPhaseTimer({
    required this.label,
    required ProfileSwitchTimingSink sink,
    int Function()? nowMicroseconds,
  }) : _sink = sink,
       _nowMicroseconds = nowMicroseconds ?? _stopwatchClock() {
    _startedAt = _nowMicroseconds();
    _lastAt = _startedAt;
  }

  final String label;
  final ProfileSwitchTimingSink _sink;
  final int Function() _nowMicroseconds;
  late final int _startedAt;
  late int _lastAt;

  void mark(String phase) {
    final now = _nowMicroseconds();
    final clampedNow = now < _lastAt ? _lastAt : now;
    _sink(
      '$label.$phase',
      Duration(microseconds: clampedNow - _lastAt),
      Duration(microseconds: clampedNow - _startedAt),
    );
    _lastAt = clampedNow;
  }

  static int Function() _stopwatchClock() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsedMicroseconds;
  }
}
