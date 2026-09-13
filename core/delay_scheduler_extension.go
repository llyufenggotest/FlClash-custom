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

func scheduleDelayTest(
	timeout time.Duration,
	run func(context.Context),
	rejected func(),
	panicHandler func(any),
) {
	epoch, blocked := profileSwitchProbeAdmissionSnapshot()
	if blocked {
		rejected()
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	ctx, release, err := manualProbes.Acquire(ctx)
	if err != nil {
		cancel()
		rejected()
		return
	}
	if !profileSwitchProbeAdmissionCurrent(epoch) {
		release()
		cancel()
		rejected()
		return
	}
	go func() {
		defer cancel()
		defer release()
		defer func() {
			if recovered := recover(); recovered != nil {
				panicHandler(recovered)
			}
		}()
		run(ctx)
	}()
}
