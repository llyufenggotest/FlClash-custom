//go:build ios && with_low_memory

package main

import (
	"context"
	"github.com/metacubex/mihomo/common/probelimit"
	"testing"
	"time"
)

func TestManualProbeOverloadRespondsOnce(t *testing.T) {
	old := manualProbes
	manualProbes = probelimit.New(1, 0)
	defer func() { manualProbes = old }()
	_, release, err := manualProbes.Acquire(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer release()
	count := 0
	handleAsyncTestDelay(&TestDelayParams{ProxyName: "missing", Timeout: 1000}, func(d *Delay) {
		count++
		if d.Value != -1 || d.Url == "" {
			t.Fatalf("invalid overload result: %+v", d)
		}
	})
	if count != 1 {
		t.Fatalf("callback count %d", count)
	}
}
func TestManualProbeExpiredRespondsOnce(t *testing.T) {
	done := make(chan *Delay, 2)
	handleAsyncTestDelay(&TestDelayParams{ProxyName: "missing", Timeout: 0}, func(d *Delay) { done <- d })
	select {
	case d := <-done:
		if d.Value != -1 {
			t.Fatal(d)
		}
	case <-time.After(time.Second):
		t.Fatal("callback missing")
	}
	select {
	case <-done:
		t.Fatal("duplicate callback")
	default:
	}
}
func TestStopCancelsProbeGenerations(t *testing.T) {
	manual, release, err := manualProbes.Acquire(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer release()
	shared, releaseShared, err := probelimit.Default.Acquire(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer releaseShared()
	cancelDelayTests()
	for _, ctx := range []context.Context{manual, shared} {
		select {
		case <-ctx.Done():
		case <-time.After(time.Second):
			t.Fatal("stop did not cancel probe")
		}
	}
}
