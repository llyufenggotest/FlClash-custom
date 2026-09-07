package main

import (
	"sync/atomic"
	"testing"

	"github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/tunnel"
)

func TestHandleSuspendRefreshesHealthChecksOnResume(t *testing.T) {
	var refreshes atomic.Int32

	previous := refreshHealthChecks
	previousRunning := isRunning
	refreshHealthChecks = func() { refreshes.Add(1) }
	t.Cleanup(func() {
		refreshHealthChecks = previous
		isRunning = previousRunning
		providerHealthChecksSuspended.Store(false)
		provider.SuspendHealthCheck(false)
		tunnel.OnRunning()
	})

	providerHealthChecksSuspended.Store(false)
	isRunning = true

	handleSuspend(false)
	if got := refreshes.Load(); got != 0 {
		t.Errorf("refreshes = %d, want none: the device was never suspended", got)
	}

	handleSuspend(true)
	if got := refreshes.Load(); got != 0 {
		t.Errorf("refreshes = %d, want none while the device is still suspended", got)
	}

	handleSuspend(false)
	if got := refreshes.Load(); got != 1 {
		t.Errorf("refreshes = %d, want exactly one on resume", got)
	}

	handleSuspend(false)
	if got := refreshes.Load(); got != 1 {
		t.Errorf("refreshes = %d, want a redundant resume to change nothing", got)
	}

	isRunning = false
	handleSuspend(true)
	handleSuspend(false)
	if got := refreshes.Load(); got != 1 {
		t.Errorf("refreshes = %d, want no probe while the listeners are stopped", got)
	}
}
