import 'package:fl_clash/common/profile_switch_timing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reports ordered phase and cumulative monotonic durations', () {
    final ticks = <int>[100, 140, 225, 220];
    var index = 0;
    final samples =
        <({String phase, Duration phaseTime, Duration totalTime})>[];
    final timer = ProfileSwitchPhaseTimer(
      label: 'android.profile_switch.7',
      nowMicroseconds: () => ticks[index++],
      sink: (phase, phaseTime, totalTime) {
        samples.add((phase: phase, phaseTime: phaseTime, totalTime: totalTime));
      },
    );

    timer.mark('barrier_acquired');
    timer.mark('core_activated');
    timer.mark('completed');

    expect(samples.map((sample) => sample.phase), [
      'android.profile_switch.7.barrier_acquired',
      'android.profile_switch.7.core_activated',
      'android.profile_switch.7.completed',
    ]);
    expect(samples.map((sample) => sample.phaseTime.inMicroseconds), [
      40,
      85,
      0,
    ]);
    expect(samples.map((sample) => sample.totalTime.inMicroseconds), [
      40,
      125,
      125,
    ]);
  });
}
