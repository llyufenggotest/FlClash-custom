//go:build ios && with_low_memory

package main

import (
	"context"
	"github.com/metacubex/mihomo/common/probelimit"
	"time"
)

var manualProbes = probelimit.New(delayBatchConcurrency*5, 0)

func cancelDelayTests() {
	manualProbes.CancelAll()
	probelimit.Default.CancelAll()
}

func scheduleDelayTest(timeout time.Duration, run func(context.Context), rejected func()) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	ctx, release, err := manualProbes.Acquire(ctx)
	if err != nil {
		cancel()
		rejected()
		return
	}
	go func() {
		defer cancel()
		defer release()
		run(ctx)
	}()
}
