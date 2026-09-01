package main

import (
	b "bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"sync"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/inbound"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/adapter/provider"
	"github.com/metacubex/mihomo/common/batch"
	"github.com/metacubex/mihomo/component/dialer"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/component/updater"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/constant/features"
	cp "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/hub/route"
	"github.com/metacubex/mihomo/listener"
	"github.com/metacubex/mihomo/log"
	rp "github.com/metacubex/mihomo/rules/provider"
	"github.com/metacubex/mihomo/tunnel"
)

var (
	currentConfig *config.Config
	version       = 0
	isRunning     = false
	runLock       sync.Mutex
	mBatch, _     = batch.New[bool](context.Background(), batch.WithConcurrencyNum[bool](delayBatchConcurrency))
	debugError    = false
)

func getExternalProvidersRaw() map[string]cp.Provider {
	eps := make(map[string]cp.Provider)
	for n, p := range tunnel.Providers() {
		if p.VehicleType() != cp.Compatible {
			eps[n] = p
		}
	}
	for n, p := range tunnel.RuleProviders() {
		if p.VehicleType() != cp.Compatible {
			eps[n] = p
		}
	}
	return eps
}

func toExternalProvider(p cp.Provider) (*ExternalProvider, error) {
	switch p.(type) {
	case *provider.ProxySetProvider:
		psp := p.(*provider.ProxySetProvider)
		return &ExternalProvider{
			Name:             psp.Name(),
			Type:             psp.Type().String(),
			VehicleType:      psp.VehicleType().String(),
			Count:            psp.Count(),
			UpdateAt:         psp.UpdatedAt(),
			Path:             psp.Vehicle().Path(),
			SubscriptionInfo: psp.GetSubscriptionInfo(),
		}, nil
	case *rp.RuleSetProvider:
		rsp := p.(*rp.RuleSetProvider)
		return &ExternalProvider{
			Name:        rsp.Name(),
			Type:        rsp.Type().String(),
			Format:      rsp.Format().String(),
			VehicleType: rsp.VehicleType().String(),
			Count:       rsp.Count(),
			UpdateAt:    rsp.UpdatedAt(),
			Path:        rsp.Vehicle().Path(),
		}, nil
	default:
		return nil, errors.New("not external provider")
	}
}

func sideUpdateExternalProvider(p cp.Provider, bytes []byte) error {
	switch p.(type) {
	case *provider.ProxySetProvider:
		psp := p.(*provider.ProxySetProvider)
		_, _, err := psp.SideUpdate(bytes)
		if err == nil {
			return err
		}
		return nil
	case rp.RuleSetProvider:
		rsp := p.(*rp.RuleSetProvider)
		_, _, err := rsp.SideUpdate(bytes)
		if err == nil {
			return err
		}
		return nil
	default:
		return errors.New("not external provider")
	}
}

func updateListeners() {
	if !isRunning {
		return
	}
	if currentConfig == nil {
		return
	}
	listeners := currentConfig.Listeners
	general := currentConfig.General
	listener.PatchInboundListeners(listeners, tunnel.Tunnel, true)

	allowLan := general.AllowLan
	listener.SetAllowLan(allowLan)
	inbound.SetSkipAuthPrefixes(general.SkipAuthPrefixes)
	inbound.SetAllowedIPs(general.LanAllowedIPs)
	inbound.SetDisAllowedIPs(general.LanDisAllowedIPs)

	bindAddress := general.BindAddress
	listener.SetBindAddress(bindAddress)
	listener.ReCreateHTTP(general.Port, tunnel.Tunnel)
	listener.ReCreateSocks(general.SocksPort, tunnel.Tunnel)
	listener.ReCreateRedir(general.RedirPort, tunnel.Tunnel)
	listener.ReCreateTProxy(general.TProxyPort, tunnel.Tunnel)
	listener.ReCreateMixed(general.MixedPort, tunnel.Tunnel)
	listener.ReCreateShadowSocks(general.ShadowSocksConfig, tunnel.Tunnel)
	listener.ReCreateVmess(general.VmessConfig, tunnel.Tunnel)
	listener.ReCreateTuic(general.TuicServer, tunnel.Tunnel)
	if !features.Android && !features.IOS {
		listener.ReCreateTun(general.Tun, tunnel.Tunnel)
	}
}

func stopListeners() {
	listener.StopListener()
}

func patchSelectGroup(mapping map[string]string) {
	for name, proxy := range tunnel.AllProxies() {
		outbound, ok := proxy.(*adapter.Proxy)
		if !ok {
			continue
		}

		selector, ok := outbound.ProxyAdapter.(outboundgroup.SelectAble)
		if !ok {
			continue
		}

		selected, exist := mapping[name]
		if !exist {
			seedUnselectedGroup(name, outbound.ProxyAdapter)
			continue
		}

		selector.ForceSet(selected)
	}
}

// selectorSeed is the slice of a selector group this seeding needs. Declared
// inline so no exported surface changes in mihomo: Selector already provides
// all three methods.
type selectorSeed interface {
	Now() string
	Proxies() []constant.Proxy
	ForceSet(name string)
}

// seedUnselectedGroup gives a group with no persisted choice a usable node.
//
// Switching to a subscription the user has never opened leaves every selector
// unpinned, and Selector.selectedProxy falls back to proxies[0] -- which
// config.go prepends with DIRECT/REJECT, so a fresh subscription silently
// routes through DIRECT until the user taps a node. Seeding the lowest-latency
// alive node instead makes the switch usable immediately; delay history
// survives in the profile cache, so a subscription used before starts on the
// node that was actually fast for it.
func seedUnselectedGroup(group string, adapter any) {
	seed, ok := adapter.(selectorSeed)
	if !ok {
		return
	}
	candidates := seed.Proxies()
	if len(candidates) == 0 {
		return
	}
	// A selection that already points at a real outbound is left alone: it may
	// come from the group's own `default` option in the profile.
	if current := seed.Now(); current != "" && !isPlaceholderOutbound(current) {
		return
	}

	const noDelaySentinel uint16 = 0xffff
	var (
		bestName  string
		bestDelay = noDelaySentinel
		fallback  string
	)
	for _, candidate := range candidates {
		name := candidate.Name()
		if isPlaceholderOutbound(name) {
			continue
		}
		if fallback == "" {
			fallback = name
		}
		if delay := candidate.LastDelayForTestUrl(constant.DefaultTestURL); delay < bestDelay {
			bestDelay = delay
			bestName = name
		}
	}

	switch {
	case bestName != "":
		seed.ForceSet(bestName)
		log.Infoln("[Group] %s seeded with fastest node %s (%dms)", group, bestName, bestDelay)
	case fallback != "":
		seed.ForceSet(fallback)
		log.Infoln("[Group] %s seeded with %s (no delay history yet)", group, fallback)
	}
}

// isPlaceholderOutbound reports whether name is one of the built-in outbounds
// mihomo prepends to every proxy list, which must never be treated as a node.
func isPlaceholderOutbound(name string) bool {
	switch name {
	case "DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE", "GLOBAL":
		return true
	default:
		return false
	}
}

func defaultSetupParams() *SetupParams {
	return &SetupParams{
		TestURL:     "https://www.gstatic.com/generate_204",
		SelectedMap: map[string]string{},
	}
}

func updateConfig(params *UpdateParams) {
	runLock.Lock()
	defer runLock.Unlock()
	if currentConfig == nil || currentConfig.General == nil {
		return
	}
	general := currentConfig.General
	if params.MixedPort != nil {
		general.MixedPort = *params.MixedPort
	}
	if params.Sniffing != nil {
		general.Sniffing = *params.Sniffing
		tunnel.SetSniffing(general.Sniffing)
	}
	if params.FindProcessMode != nil {
		general.FindProcessMode = *params.FindProcessMode
		tunnel.SetFindProcessMode(general.FindProcessMode)
	}
	if params.TCPConcurrent != nil {
		general.TCPConcurrent = *params.TCPConcurrent
		dialer.SetTcpConcurrent(general.TCPConcurrent)
	}
	if params.Interface != nil {
		general.Interface = *params.Interface
		dialer.DefaultInterface.Store(general.Interface)
	}
	if params.UnifiedDelay != nil {
		general.UnifiedDelay = *params.UnifiedDelay
		adapter.UnifiedDelay.Store(general.UnifiedDelay)
	}
	if params.Mode != nil {
		general.Mode = *params.Mode
		tunnel.SetMode(general.Mode)
	}
	if params.LogLevel != nil {
		general.LogLevel = *params.LogLevel
		log.SetLevel(general.LogLevel)
	}
	if params.IPv6 != nil {
		general.IPv6 = *params.IPv6
		resolver.DisableIPv6 = !general.IPv6
	}
	if params.ExternalController != nil {
		currentConfig.Controller.ExternalController = *params.ExternalController
		route.ReCreateServer(&route.Config{
			Addr: currentConfig.Controller.ExternalController,
		})
	}

	if params.Tun != nil {
		general.Tun.Enable = params.Tun.Enable
		if params.Tun.AutoRoute != nil {
			general.Tun.AutoRoute = *params.Tun.AutoRoute
		}
		if params.Tun.Device != nil {
			general.Tun.Device = *params.Tun.Device
		}
		if params.Tun.RouteAddress != nil {
			general.Tun.RouteAddress = *params.Tun.RouteAddress
		}
		if params.Tun.StrictRoute != nil {
			general.Tun.StrictRoute = *params.Tun.StrictRoute
		}
		if params.Tun.DisableICMPForwarding != nil {
			general.Tun.DisableICMPForwarding = *params.Tun.DisableICMPForwarding
		}
		if params.Tun.EndpointIndependentNAT != nil {
			general.Tun.EndpointIndependentNat = *params.Tun.EndpointIndependentNAT
		}
		if params.Tun.DNSHijack != nil {
			general.Tun.DNSHijack = *params.Tun.DNSHijack
		}
		if params.Tun.Stack != nil {
			general.Tun.Stack = *params.Tun.Stack
		}
	}

	if params.GeoAutoUpdate != nil {
		updater.SetGeoAutoUpdate(*params.GeoAutoUpdate)
	}
	if params.GeoUpdateInterval != nil {
		updater.SetGeoUpdateInterval(*params.GeoUpdateInterval)
	}

	updateListeners()
	if features.WithLowMemory {
		updater.StopGeoUpdater()
	} else {
		updater.RegisterGeoUpdater()
	}
}

func applyConfig(params *SetupParams) error {
	runtime.GC()
	runLock.Lock()
	defer runLock.Unlock()
	var err error
	constant.DefaultTestURL = params.TestURL
	currentConfig, err = executor.ParseWithPath(filepath.Join(constant.Path.HomeDir(), "config.yaml"))
	if err != nil {
		currentConfig, _ = config.ParseRawConfig(config.DefaultRawConfig())
	}
	applyDNSListenerOwnership(currentConfig)
	hub.ApplyConfig(currentConfig)
	patchSelectGroup(params.SelectedMap)
	updateListeners()
	if features.WithLowMemory {
		updater.StopGeoUpdater()
	} else {
		updater.RegisterGeoUpdater()
	}
	releaseReloadMemory()
	return err
}

// applyDNSListenerOwnership keeps a single process bound to the profile's DNS
// listener. Two processes racing for the same port makes one of them fail with
// "address already in use", and the loser silently loses fake-ip and sniffing.
func applyDNSListenerOwnership(cfg *config.Config) {
	if !disableDNSListener || cfg == nil || cfg.DNS == nil {
		return
	}
	if cfg.DNS.Listen == "" {
		return
	}
	log.Infoln(
		"[DNS] releasing listener %s; owner is %s",
		cfg.DNS.Listen,
		dnsListenerOwner,
	)
	cfg.DNS.Listen = ""
}

// releaseReloadMemory returns pages retained by a config reload to the OS.
// runtime.GC alone only frees the Go heap; iOS jetsam accounts phys_footprint,
// so a Network Extension that reloads a profile keeps growing until it is
// killed. Rebuilding geosite matchers is the dominant allocation here because
// the low-memory build has the matcher cache disabled.
func releaseReloadMemory() {
	if !features.WithLowMemory && !features.IOS && !features.Android {
		return
	}
	runtime.GC()
	debug.FreeOSMemory()
}

func UnmarshalJson(data []byte, v any) error {
	decoder := json.NewDecoder(b.NewReader(data))
	decoder.UseNumber()
	err := decoder.Decode(v)
	return err
}

func logError(format string, args ...interface{}) {
	log.Errorln(format, args...)
	if debugError {
		fmt.Fprintf(os.Stderr, "[ERROR] "+format+"\n", args...)
	}
}
