//go:build !(ios && with_low_memory)

package main

import (
	"context"
	"testing"
	"time"
)

func TestAsyncDelayRPCAnswersOnceWhenScheduledWorkPanics(t *testing.T) {
	withDefaultProbeScheduler(t, 1)
	response := newMethodResponse("delay-panic", nil)
	frames := captureFrames(t, func() {
		handleAsyncTestDelay(
			&TestDelayParams{ProxyName: "missing", Timeout: 1000},
			func(*Delay) { panic("delay callback exploded") },
			func(recovered any) {
				response.failure("internal_error", "internal panic", recovered)
			},
		)
		deadline := time.Now().Add(time.Second)
		for response.sent != nil && !response.sent.Load() && time.Now().Before(deadline) {
			time.Sleep(time.Millisecond)
		}
		time.Sleep(50 * time.Millisecond)
	})
	if len(frames) != 1 {
		t.Fatalf("captured %d frames, want one panic response", len(frames))
	}
	if !response.sent.Load() {
		t.Fatal("panic did not terminate the RPC response")
	}
}

func TestCancelableSchedulerReportsPanicsOnce(t *testing.T) {
	withDefaultProbeScheduler(t, 1)
	panicked := make(chan any, 2)
	scheduleDelayTest(time.Second, func(context.Context) {
		panic("delay exploded")
	}, func() {
		t.Error("unexpected rejection")
	}, func(recovered any) {
		panicked <- recovered
	})
	select {
	case recovered := <-panicked:
		if recovered != "delay exploded" {
			t.Fatalf("panic = %v", recovered)
		}
	case <-time.After(time.Second):
		t.Fatal("async delay panic was not reported")
	}
	select {
	case recovered := <-panicked:
		t.Fatalf("panic reported twice: %v", recovered)
	case <-time.After(100 * time.Millisecond):
	}
}

func TestCancelableSchedulerDropsQueuedRPCWork(t *testing.T) {
	withDefaultProbeScheduler(t, 1)
	manualProbeSlots <- struct{}{}
	called := make(chan struct{}, 1)
	rejected := make(chan struct{}, 1)
	scheduleDelayTest(time.Minute, func(ctx context.Context) {
		called <- struct{}{}
	}, func() { rejected <- struct{}{} }, func(recovered any) {
		t.Errorf("unexpected panic: %v", recovered)
	})
	cancelDelayTests()
	<-manualProbeSlots
	select {
	case <-rejected:
	case <-time.After(time.Second):
		t.Fatal("cancelled queued RPC did not complete its callback")
	}
	select {
	case <-called:
		t.Fatal("cancelled queued RPC work ran")
	case <-time.After(100 * time.Millisecond):
	}
}
