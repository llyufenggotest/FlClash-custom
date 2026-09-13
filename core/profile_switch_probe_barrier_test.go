package main

import "testing"

func TestProfileSwitchProbeBarrierBlocksAndResumesAdmission(t *testing.T) {
	const token = "switch-test"
	setProfileSwitchProbeBarrier(token, false)
	t.Cleanup(func() { setProfileSwitchProbeBarrier(token, false) })
	_, blocked := profileSwitchProbeAdmissionSnapshot()
	if blocked {
		t.Fatal("probe admission unexpectedly blocked before switch")
	}

	if !setProfileSwitchProbeBarrier(token, true) {
		t.Fatal("failed to acquire profile switch barrier")
	}
	epoch, blocked := profileSwitchProbeAdmissionSnapshot()
	if !blocked {
		t.Fatal("profile switch did not block new probe admission")
	}

	if setProfileSwitchProbeBarrier("stale-switch", false) {
		t.Fatal("stale owner released the profile switch barrier")
	}
	if profileSwitchProbeAdmissionCurrent(epoch) {
		t.Fatal("blocked epoch admitted a probe")
	}

	if !setProfileSwitchProbeBarrier(token, false) {
		t.Fatal("current owner failed to release profile switch barrier")
	}
	if profileSwitchProbeAdmissionCurrent(epoch) {
		t.Fatal("old admission epoch survived close/open cycle")
	}
	_, blocked = profileSwitchProbeAdmissionSnapshot()
	if blocked {
		t.Fatal("probe admission remained blocked after switch")
	}
}
