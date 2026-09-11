//go:build !(ios && with_low_memory)

package main

import (
	"context"
	"sync"
	"time"
)

// Keep legacy async waiting and per-probe timeout, without Batch's unused,
// lifetime-growing result map. A generation counter lets profile switching
// discard queued stale work; the shared context cancels active probes.
var (
	manualProbeSlots = make(chan struct{}, delayBatchConcurrency)
	manualProbeMu    sync.Mutex
	manualProbeCtx   context.Context
	manualProbeStop  context.CancelFunc
	manualProbeGen   uint64
)

func manualProbeSnapshot() (context.Context, uint64) {
	manualProbeMu.Lock()
	defer manualProbeMu.Unlock()
	if manualProbeCtx == nil {
		manualProbeCtx, manualProbeStop = context.WithCancel(context.Background())
	}
	return manualProbeCtx, manualProbeGen
}

func manualProbeGenerationCurrent(generation uint64) bool {
	manualProbeMu.Lock()
	defer manualProbeMu.Unlock()
	return generation == manualProbeGen
}

func cancelDelayTests() {
	manualProbeMu.Lock()
	if manualProbeStop != nil {
		manualProbeStop()
	}
	manualProbeGen++
	manualProbeCtx, manualProbeStop = context.WithCancel(context.Background())
	manualProbeMu.Unlock()
}

func scheduleDelayTest(timeout time.Duration, run func(context.Context), rejected func()) {
	generationContext, generation := manualProbeSnapshot()
	go func() {
		select {
		case manualProbeSlots <- struct{}{}:
			defer func() { <-manualProbeSlots }()
		case <-generationContext.Done():
			rejected()
			return
		}
		if generationContext.Err() != nil || !manualProbeGenerationCurrent(generation) {
			rejected()
			return
		}
		ctx, cancel := context.WithTimeout(generationContext, timeout)
		defer cancel()
		run(ctx)
	}()
}
