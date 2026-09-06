//go:build !(ios && with_low_memory)

package main

import (
	"context"
	"sync/atomic"
	"testing"
	"time"
)

func TestDefaultSchedulerQueuesWithoutRejectingOrCanceling(t *testing.T) {
	old := manualProbeSlots
	manualProbeSlots = make(chan struct{}, 1)
	defer func() { manualProbeSlots = old }()
	manualProbeSlots <- struct{}{}
	done := make(chan error, 300)
	var rejected atomic.Int32
	for i := 0; i < 300; i++ {
		scheduleDelayTest(time.Second, func(ctx context.Context) { done <- ctx.Err() }, func() { rejected.Add(1) })
	}
	cancelDelayTests()
	// Waiting time must not consume the per-probe timeout.
	time.Sleep(1100 * time.Millisecond)
	select {
	case <-done:
		t.Fatal("scheduler ran through occupied slot")
	default:
	}
	<-manualProbeSlots
	for i := 0; i < 300; i++ {
		select {
		case err := <-done:
			if err != nil {
				t.Fatalf("queued probe canceled: %v", err)
			}
		case <-time.After(5 * time.Second):
			t.Fatal("queued probe lost")
		}
	}
	// Drain the final worker before restoring the package variable.
	manualProbeSlots <- struct{}{}
	<-manualProbeSlots
	if rejected.Load() != 0 {
		t.Fatalf("rejected %d probes", rejected.Load())
	}
}

func TestDefaultSchedulerStopDoesNotCancelActive(t *testing.T) {
	entered := make(chan context.Context, 1)
	unblock := make(chan struct{})
	done := make(chan struct{})
	scheduleDelayTest(time.Minute, func(ctx context.Context) { entered <- ctx; <-unblock; close(done) }, func() { t.Error("unexpected rejection") })
	ctx := <-entered
	cancelDelayTests()
	if ctx.Err() != nil {
		t.Fatalf("stop canceled legacy probe: %v", ctx.Err())
	}
	close(unblock)
	<-done
}
