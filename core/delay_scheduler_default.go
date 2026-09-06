//go:build !(ios && with_low_memory)

package main

import (
	"context"
	"time"
)

// Keep legacy async waiting and per-probe timeout, without Batch's unused,
// lifetime-growing result map. No process-wide rejection or stop cancellation.
var manualProbeSlots = make(chan struct{}, delayBatchConcurrency)

func cancelDelayTests() {}

func scheduleDelayTest(timeout time.Duration, run func(context.Context), rejected func()) {
	go func() {
		manualProbeSlots <- struct{}{}
		defer func() { <-manualProbeSlots }()
		ctx, cancel := context.WithTimeout(context.Background(), timeout)
		defer cancel()
		run(ctx)
	}()
}
