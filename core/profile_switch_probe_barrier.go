package main

import (
	"sync"

	"github.com/metacubex/mihomo/adapter/provider"
)

// Profile-switch probe admission has an owner token. A newer switch replaces
// the owner; a late older switch cannot reopen admission. The epoch catches a
// request that races through close -> cancel -> reopen while acquiring a slot.
var profileSwitchProbeBarrier = struct {
	sync.Mutex
	owner   string
	blocked bool
	epoch   uint64
}{}

func setProfileSwitchProbeBarrier(token string, suspended bool) bool {
	profileSwitchProbeBarrier.Lock()
	wasBlocked := profileSwitchProbeBarrier.blocked
	if suspended {
		profileSwitchProbeBarrier.owner = token
		profileSwitchProbeBarrier.blocked = true
		profileSwitchProbeBarrier.epoch++
	} else {
		if profileSwitchProbeBarrier.owner != token {
			profileSwitchProbeBarrier.Unlock()
			return false
		}
		profileSwitchProbeBarrier.owner = ""
		profileSwitchProbeBarrier.blocked = false
		profileSwitchProbeBarrier.epoch++
	}
	profileSwitchProbeBarrier.Unlock()

	updateProviderHealthCheckSuspension()
	if wasBlocked && !suspended && !providerHealthChecksSuspended() && isRunning.Load() {
		refreshHealthChecks()
	}
	if suspended {
		cancelDelayTests()
	}
	return true
}

func profileSwitchProbeAdmissionSnapshot() (uint64, bool) {
	profileSwitchProbeBarrier.Lock()
	defer profileSwitchProbeBarrier.Unlock()
	return profileSwitchProbeBarrier.epoch, profileSwitchProbeBarrier.blocked
}

func profileSwitchProbeAdmissionCurrent(epoch uint64) bool {
	profileSwitchProbeBarrier.Lock()
	defer profileSwitchProbeBarrier.Unlock()
	return !profileSwitchProbeBarrier.blocked && profileSwitchProbeBarrier.epoch == epoch
}

func providerHealthChecksSuspended() bool {
	profileSwitchProbeBarrier.Lock()
	blocked := profileSwitchProbeBarrier.blocked
	profileSwitchProbeBarrier.Unlock()
	return isSuspended.Load() || blocked
}

func updateProviderHealthCheckSuspension() {
	provider.SuspendHealthCheck(providerHealthChecksSuspended())
}
