//go:build with_low_memory

// The bypass is a with_low_memory behaviour, so these end-to-end assertions only
// hold under that tag. Without it the same file would demand DIRECT pinning from
// a build that deliberately leaves routing to the platform.
package main

import (
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/metacubex/mihomo/config"
	C "github.com/metacubex/mihomo/constant"
)

// End-to-end guard for the routing loop found in the 2026-08-30 device trace.
//
// The extension's core receives traffic captured from the TUN device, including
// the sockets the *app* process opens to probe every node (delay tests, IP
// checks, subscription refresh). With a domain-only ruleset nothing covers the
// proxy servers' own IPs, so those probes fell through to MATCH and were dialled
// *through a proxy*: "connect to node_X" tunneled into node_Y. Each probe became
// a live tunnel connection, and the failing subscription has 137 distinct server
// IPs, so footprint went 32 -> 46 MB in ~3 s and jetsam killed the extension.
//
// This lives in package main (not config) on purpose: only here is
// hub/executor's temporaryUpdateGeneral linkname satisfied, so this is the one
// place the FULL config.Parse pipeline can be exercised — rule providers,
// subscription rule ordering and all. It is the difference between asserting on
// the generated rules and asserting on what the core will actually match.
//
// Set PROFILE_YAML_DIR to run against the real subscriptions.
func parsedProfiles(t *testing.T) map[string]*config.Config {
	t.Helper()
	dir := os.Getenv("PROFILE_YAML_DIR")
	if dir == "" {
		t.Skip("set PROFILE_YAML_DIR to the directory holding the real subscription yamls")
	}
	paths, err := filepath.Glob(filepath.Join(dir, "*.yaml"))
	if err != nil || len(paths) == 0 {
		t.Fatalf("no yaml files in %s (err %v)", dir, err)
	}
	sort.Strings(paths)

	out := map[string]*config.Config{}
	for _, path := range paths {
		buf, readErr := os.ReadFile(path)
		if readErr != nil {
			t.Fatalf("read %s: %v", path, readErr)
		}
		cfg, parseErr := config.Parse(buf)
		if parseErr != nil {
			t.Fatalf("Parse %s: %v", filepath.Base(path), parseErr)
		}
		out[filepath.Base(path)] = cfg
	}
	return out
}

// matchThrough walks the real rule list the way the tunnel does and reports the
// outbound that would be chosen for a destination IP.
func matchThrough(rules []C.Rule, ip netip.Addr) (string, bool) {
	metadata := &C.Metadata{DstIP: ip, DstPort: 443}
	for _, rule := range rules {
		if ok, adapterName := rule.Match(metadata, C.RuleMatchHelper{}); ok {
			return adapterName, true
		}
	}
	return "", false
}

func TestProxyServersNeverReEnterTunnel(t *testing.T) {
	profiles := parsedProfiles(t)

	for name, cfg := range profiles {
		t.Run(name, func(t *testing.T) {
			// Collect every server address this profile dials out to.
			servers := map[netip.Addr]string{}
			for proxyName, proxy := range cfg.Proxies {
				addr := proxy.Addr()
				if addr == "" {
					continue
				}
				ap, splitErr := netip.ParseAddrPort(addr)
				if splitErr != nil {
					// Hostname-based servers are covered by DOMAIN rules, which
					// an IP-only probe cannot exercise; skip them here.
					continue
				}
				servers[ap.Addr()] = proxyName
			}
			if len(servers) == 0 {
				t.Skip("no IP-addressed servers in this profile")
			}

			var looped []string
			for ip, proxyName := range servers {
				adapterName, matched := matchThrough(cfg.Rules, ip)
				if !matched {
					looped = append(looped, ip.String()+" ("+proxyName+") -> no rule")
					continue
				}
				if adapterName != "DIRECT" {
					looped = append(looped, ip.String()+" ("+proxyName+") -> "+adapterName)
				}
			}
			sort.Strings(looped)

			t.Logf("%s: %d IP-addressed servers, %d would re-enter the tunnel",
				name, len(servers), len(looped))
			for i, entry := range looped {
				if i >= 5 {
					t.Logf("  ... and %d more", len(looped)-5)
					break
				}
				t.Logf("  LOOP %s", entry)
			}
			if len(looped) > 0 {
				t.Errorf("%s: %d/%d proxy servers would be dialled through a proxy",
					name, len(looped), len(servers))
			}
		})
	}
}

// The bypass must not swallow ordinary traffic: a profile that routes everything
// through a proxy must still do so for non-server destinations.
func TestBypassDoesNotHijackOrdinaryTraffic(t *testing.T) {
	profiles := parsedProfiles(t)

	// Public addresses that are not proxy servers in any of these subscriptions.
	probes := []string{"93.184.216.34", "1.1.1.1", "8.8.8.8"}

	for name, cfg := range profiles {
		servers := map[netip.Addr]bool{}
		for _, proxy := range cfg.Proxies {
			if addr := proxy.Addr(); addr != "" {
				if ap, err := netip.ParseAddrPort(addr); err == nil {
					servers[ap.Addr()] = true
				}
			}
		}
		for _, probe := range probes {
			ip := netip.MustParseAddr(probe)
			if servers[ip] {
				continue
			}
			if _, matched := matchThrough(cfg.Rules, ip); !matched {
				t.Errorf("%s: %s matched no rule at all", name, probe)
			}
		}
	}
}

// The bypass rules must sit ahead of the profile's own rules, or a subscription
// shipping its own MATCH (all five of these do) would win.
func TestBypassRulesArePrepended(t *testing.T) {
	profiles := parsedProfiles(t)

	for name, cfg := range profiles {
		if len(cfg.Rules) == 0 {
			t.Errorf("%s: no rules at all", name)
			continue
		}

		// Expected bypass payloads: /32 or /128 for IPs, the bare host for
		// hostname servers.
		want := map[string]bool{}
		for _, proxy := range cfg.Proxies {
			addr := proxy.Addr()
			if addr == "" {
				continue
			}
			host, _, err := net.SplitHostPort(addr)
			if err != nil || host == "" {
				continue
			}
			if ip, parseErr := netip.ParseAddr(host); parseErr == nil {
				ip = ip.Unmap().WithZone("")
				want[netip.PrefixFrom(ip, ip.BitLen()).String()] = true
			} else {
				want[strings.ToLower(host)] = true
			}
		}
		if len(want) == 0 {
			t.Errorf("%s: no server addresses found", name)
			continue
		}

		// Counting "leading DIRECT ip rules" is not enough: several of these
		// profiles start their OWN rules with DIRECT ip rules too, so a loose
		// counter runs past the bypass block. Assert on identity instead.
		if len(cfg.Rules) < len(want) {
			t.Errorf("%s: only %d rules for %d servers", name, len(cfg.Rules), len(want))
			continue
		}
		got := map[string]bool{}
		for i := 0; i < len(want); i++ {
			rule := cfg.Rules[i]
			if rule.Adapter() != "DIRECT" {
				t.Errorf("%s: rule[%d] %s %q -> %q, want DIRECT",
					name, i, rule.RuleType().String(), rule.Payload(), rule.Adapter())
				continue
			}
			got[rule.Payload()] = true
		}

		var missing []string
		for payload := range want {
			if !got[payload] {
				missing = append(missing, payload)
			}
		}
		sort.Strings(missing)

		t.Logf("%s: %d server addresses pinned in the first %d rules (%d total)",
			name, len(want)-len(missing), len(want), len(cfg.Rules))
		for i, payload := range missing {
			if i >= 5 {
				t.Logf("  ... and %d more", len(missing)-5)
				break
			}
			t.Logf("  MISSING %s", payload)
		}
		if len(missing) > 0 {
			t.Errorf("%s: %d server addresses are not pinned at the front",
				name, len(missing))
		}
	}
}
