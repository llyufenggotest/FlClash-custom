//go:build !(ios && with_low_memory)

package main

import (
	"context"
	"sync/atomic"
	"testing"
	"time"
)

func withDefaultProbeScheduler(t *testing.T, slots int) {
	t.Helper()
	oldSlots := manualProbeSlots
	manualProbeMu.Lock()
	oldCtx, oldStop, oldGen := manualProbeCtx, manualProbeStop, manualProbeGen
	manualProbeSlots = make(chan struct{}, slots)
	manualProbeCtx, manualProbeStop = context.WithCancel(context.Background())
	manualProbeMu.Unlock()
	t.Cleanup(func() {
		cancelDelayTests()
		manualProbeMu.Lock()
		manualProbeSlots = oldSlots
		manualProbeCtx, manualProbeStop, manualProbeGen = oldCtx, oldStop, oldGen
		manualProbeMu.Unlock()
	})
}

func TestDefaultSchedulerQueuesWithoutRejecting(t *testing.T) {
	withDefaultProbeScheduler(t, 1)
	manualProbeSlots <- struct{}{}
	done := make(chan error, 300)
	var rejected atomic.Int32
	for i := 0; i < 300; i++ {
		scheduleDelayTest(
			time.Second,
			func(ctx context.Context) { done <- ctx.Err() },
			func() { rejected.Add(1) },
			func(recovered any) { t.Errorf("unexpected panic: %v", recovered) },
		)
	}
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
	if rejected.Load() != 0 {
		t.Fatalf("rejected %d probes", rejected.Load())
	}
}

func TestDefaultSchedulerProfileSwitchCancelsQueuedAndActive(t *testing.T) {
	withDefaultProbeScheduler(t, 1)
	entered := make(chan context.Context, 1)
	activeDone := make(chan error, 1)
	queuedRan := make(chan struct{}, 1)
	queuedRejected := make(chan struct{}, 1)
	scheduleDelayTest(time.Minute, func(ctx context.Context) {
		entered <- ctx
		<-ctx.Done()
		activeDone <- ctx.Err()
	}, func() { t.Error("unexpected rejection") }, func(recovered any) {
		t.Errorf("unexpected panic: %v", recovered)
	})
	<-entered
	scheduleDelayTest(time.Minute, func(ctx context.Context) {
		queuedRan <- struct{}{}
	}, func() { queuedRejected <- struct{}{} }, func(recovered any) {
		t.Errorf("unexpected panic: %v", recovered)
	})

	cancelDelayTests()
	select {
	case err := <-activeDone:
		if err != context.Canceled {
			t.Fatalf("active probe error = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("active probe was not canceled")
	}
	select {
	case <-queuedRejected:
	case <-time.After(time.Second):
		t.Fatal("queued probe callback was not completed")
	}
	time.Sleep(50 * time.Millisecond)
	select {
	case <-queuedRan:
		t.Fatal("queued stale probe ran after cancellation")
	default:
	}
}

func TestDefaultSchedulerNewGenerationRunsAfterCancellation(t *testing.T) {
	withDefaultProbeScheduler(t, 1)
	cancelDelayTests()
	done := make(chan error, 1)
	scheduleDelayTest(time.Second, func(ctx context.Context) { done <- ctx.Err() }, func() {
		t.Error("unexpected rejection")
	}, func(recovered any) {
		t.Errorf("unexpected panic: %v", recovered)
	})
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("new generation inherited cancellation: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("new generation did not run")
	}
}
