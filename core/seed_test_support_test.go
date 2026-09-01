package main

import (
	C "github.com/metacubex/mihomo/constant"
)

// delayProxy is a C.Proxy stub whose only meaningful behaviour is the recorded
// latency, which is what node seeding ranks on.
type delayProxy struct {
	C.Proxy
	name  string
	delay uint16
}

func (d *delayProxy) Name() string                     { return d.name }
func (d *delayProxy) LastDelayForTestUrl(string) uint16 { return d.delay }
func (d *delayProxy) AliveForTestUrl(string) bool       { return d.delay != 0xffff }

func newDelayProxy(name string, delay uint16) C.Proxy {
	return &delayProxy{name: name, delay: delay}
}
