package main

import (
	"testing"

	C "github.com/metacubex/mihomo/constant"
)

// seedProbe records what seedUnselectedGroup decided. It implements exactly the
// selectorSeed slice used by production code.
type seedProbe struct {
	now      string
	proxies  []C.Proxy
	forceSet []string
}

func (s *seedProbe) Now() string            { return s.now }
func (s *seedProbe) Proxies() []C.Proxy     { return s.proxies }
func (s *seedProbe) ForceSet(name string)   { s.forceSet = append(s.forceSet, name); s.now = name }

// A subscription the user has never opened has no persisted selection, so every
// selector falls back to proxies[0] -- which mihomo prepends with DIRECT. The
// switch then silently routes through DIRECT until a node is tapped. Seeding
// must pick the fastest real node instead.
func TestSeedPicksFastestRealNode(t *testing.T) {
	probe := &seedProbe{
		now: "DIRECT",
		proxies: []C.Proxy{
			newDelayProxy("DIRECT", 0),
			newDelayProxy("REJECT", 0),
			newDelayProxy("slow-node", 480),
			newDelayProxy("fast-node", 62),
			newDelayProxy("dead-node", 0xffff),
		},
	}

	seedUnselectedGroup("节点选择", probe)

	if len(probe.forceSet) != 1 || probe.forceSet[0] != "fast-node" {
		t.Fatalf("expected the lowest-latency node to be seeded, got %v", probe.forceSet)
	}
}

// Without delay history (a brand new subscription that has not been probed yet)
// every candidate reports the 0xffff sentinel. Seeding must still land on a real
// node rather than leaving the group on DIRECT.
func TestSeedFallsBackToFirstRealNodeWithoutHistory(t *testing.T) {
	probe := &seedProbe{
		now: "DIRECT",
		proxies: []C.Proxy{
			newDelayProxy("DIRECT", 0),
			newDelayProxy("REJECT", 0),
			newDelayProxy("hk-01", 0xffff),
			newDelayProxy("hk-02", 0xffff),
		},
	}

	seedUnselectedGroup("节点选择", probe)

	if len(probe.forceSet) != 1 || probe.forceSet[0] != "hk-01" {
		t.Fatalf("expected the first real node as fallback, got %v", probe.forceSet)
	}
}

// A group whose selection already points at a real node keeps it: it may come
// from the profile's own `default` option, and overriding that would ignore the
// author's intent.
func TestSeedKeepsAnExistingRealSelection(t *testing.T) {
	probe := &seedProbe{
		now: "chosen-node",
		proxies: []C.Proxy{
			newDelayProxy("DIRECT", 0),
			newDelayProxy("chosen-node", 300),
			newDelayProxy("faster-node", 40),
		},
	}

	seedUnselectedGroup("节点选择", probe)

	if len(probe.forceSet) != 0 {
		t.Fatalf("an existing real selection must be preserved, got %v", probe.forceSet)
	}
}

// A group that only contains placeholders (an empty subscription) must be left
// alone instead of being pinned to REJECT.
func TestSeedLeavesPlaceholderOnlyGroupAlone(t *testing.T) {
	probe := &seedProbe{
		now: "DIRECT",
		proxies: []C.Proxy{
			newDelayProxy("DIRECT", 0),
			newDelayProxy("REJECT", 0),
			newDelayProxy("COMPATIBLE", 0),
		},
	}

	seedUnselectedGroup("节点选择", probe)

	if len(probe.forceSet) != 0 {
		t.Fatalf("a group without real nodes must not be seeded, got %v", probe.forceSet)
	}
}

func TestPlaceholderOutboundsAreNeverTreatedAsNodes(t *testing.T) {
	for _, name := range []string{"DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE", "GLOBAL"} {
		if !isPlaceholderOutbound(name) {
			t.Fatalf("%s must be recognised as a placeholder outbound", name)
		}
	}
	for _, name := range []string{"hk-01", "direct-node", "my REJECT node", ""} {
		if isPlaceholderOutbound(name) {
			t.Fatalf("%q is a real node name and must not be filtered out", name)
		}
	}
}
