//go:build !(ios && with_low_memory)

package main

import (
	"context"
	"testing"
	"time"
)

func TestCancelableSchedulerDropsQueuedRPCWork(t *testing.T) {
	withDefaultProbeScheduler(t, 1)
	manualProbeSlots <- struct{}{}
	called := make(chan struct{}, 1)
	rejected := make(chan struct{}, 1)
	scheduleDelayTest(time.Minute, func(ctx context.Context) {
		called <- struct{}{}
	}, func() { rejected <- struct{}{} })
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
