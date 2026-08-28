package main

import (
	"cmp"
	"context"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"strconv"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/common/observable"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/component/age"
	"github.com/metacubex/mihomo/component/mmdb"
	"github.com/metacubex/mihomo/component/resolver"
	"github.com/metacubex/mihomo/component/updater"
	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/constant/features"
	cp "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/listener"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
	"github.com/metacubex/tailscale/ipn/ipnstate"
	"golang.org/x/exp/slices"
)

var (
	isInit            atomic.Bool
	externalProviders = map[string]cp.Provider{}
	logSubscriber     observable.Subscription[log.Event]
)

var (
	logNotifyMutex   sync.Mutex
	logNotifyEnabled bool
	logNotifyCache   [maxCachedLogNotify]StampedLogEvent
	logNotifyStart   int
	logNotifyLen     int
)

var (
	requestNotifyMutex   sync.Mutex
	requestNotifyEnabled bool
	requestNotifyCache   [maxCachedRequestNotify]*statistic.TrackerInfo
	requestNotifyStart   int
	requestNotifyLen     int
)

const (
	maxCachedLogNotify     = 100
	maxCachedRequestNotify = 100
)

type StampedLogEvent struct {
	LogLevel log.LogLevel
	Payload  string
	Time     int64
}

func handleInitClash(params *InitParams) bool {
	runLock.Lock()
	defer runLock.Unlock()
	version = params.Version
	constant.SetHomeDir(params.HomeDir)
	if secondaryCacheFileName != "" {
		// Avoid racing the process that owns the canonical bbolt cache.
		constant.SetCacheFileName(secondaryCacheFileName)
	}
	constant.Path.MMDB()
	constant.Path.ASN()
	constant.Path.GeoIP()
	constant.Path.GeoSite()
	if features.IOS && !features.WithLowMemory {
		constant.SetSaveMatcherCache(true)
	}
	isInit.Store(true)
	return true
}

func handleStartListener() bool {
	runLock.Lock()
	defer runLock.Unlock()
	isRunning = true
	updateListeners()
	resolver.ResetConnection()
	return true
}

func handleStopListener() bool {
	runLock.Lock()
	defer runLock.Unlock()
	isRunning = false
	listener.StopListener()
	resolver.ResetConnection()
	return true
}

func handleGetIsInit() bool {
	return isInit.Load()
}

func handleForceGC() {
	log.Infoln("[APP] request force GC")
	runtime.GC()
	if features.Android || features.IOS {
		debug.FreeOSMemory()
	}
}

func handleShutdown() bool {
	stopListeners()
	executor.Shutdown()
	handleForceGC()
	isInit.Store(false)
	return true
}

func handleValidateConfig(data string) string {
	_, err := config.UnmarshalRawConfig([]byte(data))
	if err != nil {
		return err.Error()
	}
	return ""
}

func handleDecryptAgeConfig(params *DecryptAgeConfigParams) string {
	decrypted, err := age.DecryptBytes([]byte(params.Data), params.AgeSecretKey)
	if err != nil {
		return ""
	}
	return string(decrypted)
}

func handleGetProxies() ProxiesData {
	runLock.Lock()
	defer runLock.Unlock()

	nameList := config.GetProxyNameList()

	proxies := tunnel.AllProxies()

	hasGlobal := false

	allNames := make([]string, 0, len(nameList)+1)

	for _, name := range nameList {
		if name == "GLOBAL" {
			hasGlobal = true
		}

		p, ok := proxies[name]
		if !ok || p == nil {
			continue
		}
		switch p.Type() {
		case constant.Selector, constant.URLTest, constant.Fallback, constant.Relay, constant.LoadBalance:
			allNames = append(allNames, name)
		default:
		}
	}

	if !hasGlobal {
		if p, ok := proxies["GLOBAL"]; ok && p != nil {
			allNames = append([]string{"GLOBAL"}, allNames...)
		}
	}

	return ProxiesData{
		All:     allNames,
		Proxies: proxies,
	}
}

func handleChangeProxy(params *ChangeProxyParams, fn func(string string)) {
	runLock.Lock()
	go func() {
		defer runLock.Unlock()
		groupName := params.GroupName
		proxyName := params.ProxyName
		proxies := tunnel.AllProxies()
		group, ok := proxies[groupName]
		if !ok {
			fn("Not found group")
			return
		}
		adapterProxy, ok := group.(*adapter.Proxy)
		if !ok {
			fn("Group has invalid proxy type")
			return
		}
		selector, ok := adapterProxy.ProxyAdapter.(outboundgroup.SelectAble)
		if !ok {
			fn("Group is not selectable")
			return
		}
		proxyGroup, ok := adapterProxy.ProxyAdapter.(outboundgroup.ProxyGroup)
		if !ok {
			fn("Group has invalid proxy type")
			return
		}
		if proxyName == "" {
			selector.ForceSet(proxyName)
		} else {
			err := selector.Set(proxyName)
			if err != nil {
				fn(err.Error())
				return
			}
		}
		if params.CloseConnections {
			closeConnectionsForSelection(groupName, proxyGroup.Now())
		} else {
			resolver.ResetConnection()
		}

		fn("")
		return
	}()
}

func handleGetTraffic(onlyStatisticsProxy bool) Traffic {
	up, down := statistic.DefaultManager.NowTraffic(onlyStatisticsProxy)
	return Traffic{
		Up:   up,
		Down: down,
	}
}

func handleGetTotalTraffic(onlyStatisticsProxy bool) Traffic {
	up, down := statistic.DefaultManager.TotalTraffic(onlyStatisticsProxy)
	return Traffic{
		Up:   up,
		Down: down,
	}
}

func handleResetTraffic() {
	statistic.DefaultManager.ResetStatistic()
}

func handleAsyncTestDelay(params *TestDelayParams, fn func(*Delay)) {
	batchKey := params.ProxyName + "\x00" + params.TestUrl
	mBatch.Go(batchKey, func() (bool, error) {
		testUrl := params.TestUrl
		if testUrl == "" {
			testUrl = constant.DefaultTestURL
		}
		delayData := &Delay{
			Name:  params.ProxyName,
			Url:   testUrl,
			Value: -1,
		}

		expectedStatus, err := utils.NewUnsignedRanges[uint16]("")
		if err != nil {
			fn(delayData)
			return false, nil
		}

		ctx, cancel := context.WithTimeout(context.Background(), time.Millisecond*time.Duration(params.Timeout))
		defer cancel()

		proxies := tunnel.AllProxies()
		proxy := proxies[params.ProxyName]

		if proxy == nil {
			fn(delayData)
			return false, nil
		}
		delay, err := proxy.URLTest(ctx, testUrl, expectedStatus)
		if err != nil || delay == 0 {
			fn(delayData)
			return false, nil
		}

		delayData.Value = int32(delay)
		fn(delayData)
		return false, nil
	})
}

func handleGetConnections() *statistic.Snapshot {
	runLock.Lock()
	defer runLock.Unlock()
	return statistic.DefaultManager.Snapshot()
}

func handleCloseConnections() bool {
	runLock.Lock()
	defer runLock.Unlock()
	closeConnections()
	return true
}

func closeConnections() {
	statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
		_ = c.Close()
		return true
	})
}

func closeConnectionsForSelection(groupName string, proxyName string) {
	statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
		if chainUsesOtherSelection(c.Info().Chain, groupName, proxyName) {
			_ = c.Close()
		}
		return true
	})
}

func chainUsesOtherSelection(chain constant.Chain, groupName string, proxyName string) bool {
	for index, chainProxyName := range chain {
		if chainProxyName == groupName {
			return index == 0 || chain[index-1] != proxyName
		}
	}
	return false
}

func handleResetConnections() bool {
	runLock.Lock()
	defer runLock.Unlock()
	resolver.ResetConnection()
	return true
}

func handleCloseConnection(connectionId string) bool {
	runLock.Lock()
	defer runLock.Unlock()
	c := statistic.DefaultManager.Get(connectionId)
	if c == nil {
		return false
	}
	_ = c.Close()
	return true
}

func handleGetExternalProviders() []ExternalProvider {
	runLock.Lock()
	defer runLock.Unlock()
	externalProviders = getExternalProvidersRaw()
	eps := make([]ExternalProvider, 0)
	for _, p := range externalProviders {
		externalProvider, err := toExternalProvider(p)
		if err != nil {
			continue
		}
		eps = append(eps, *externalProvider)
	}
	slices.SortFunc(eps, func(a, b ExternalProvider) int {
		return cmp.Compare(a.Name, b.Name)
	})
	return eps
}

func handleGetExternalProvider(externalProviderName string) *ExternalProvider {
	runLock.Lock()
	defer runLock.Unlock()
	externalProvider, exist := externalProviders[externalProviderName]
	if !exist {
		return nil
	}
	e, err := toExternalProvider(externalProvider)
	if err != nil {
		return nil
	}
	return e
}

func handleGetOverlayNetworkStatus(params *GetOverlayNetworkStatusParams) []OverlayNetworkStatus {
	runLock.Lock()
	defer runLock.Unlock()

	proxies := make(map[string]*adapter.Proxy)
	for _, proxy := range tunnel.AllProxies() {
		if proxy == nil || proxy.Type() != constant.Tailscale && proxy.Type() != constant.ZeroTier {
			continue
		}
		if adapterProxy, ok := proxy.(*adapter.Proxy); ok {
			proxies[proxy.Name()] = adapterProxy
		}
	}

	statuses := make([]OverlayNetworkStatus, len(params.Targets))
	var waitGroup sync.WaitGroup
	for index, target := range params.Targets {
		proxy := proxies[target.Name]
		waitGroup.Add(1)
		go func() {
			defer waitGroup.Done()
			statuses[index] = getOverlayNetworkStatus(target, proxy, false)
		}()
	}
	waitGroup.Wait()
	return statuses
}

func handleActivateOverlayNetwork(params *ActivateOverlayNetworkParams) OverlayNetworkStatus {
	runLock.Lock()
	defer runLock.Unlock()

	target := OverlayNetworkTarget{
		Name:  params.Name,
		Kind:  params.Kind,
		Level: overlayNetworkSummary,
	}
	proxy, exists := tunnel.AllProxies()[params.Name]
	if !exists || proxy == nil {
		return getOverlayNetworkStatus(target, nil, true)
	}
	adapterProxy, ok := proxy.(*adapter.Proxy)
	if !ok {
		return getOverlayNetworkStatus(target, nil, true)
	}
	return getOverlayNetworkStatus(target, adapterProxy, true)
}

func handlePingTailscaleNode(params *TailscalePingParams) (*TailscalePingResult, error) {
	runLock.Lock()
	defer runLock.Unlock()

	proxy, exists := tunnel.AllProxies()[params.Name]
	if !exists || proxy == nil || proxy.Type() != constant.Tailscale {
		return nil, fmt.Errorf("Tailscale outbound %q not found", params.Name)
	}
	adapterProxy, ok := proxy.(*adapter.Proxy)
	if !ok {
		return nil, fmt.Errorf("Tailscale outbound %q is unavailable", params.Name)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	latency, err := outbound.PingTailscaleNode(ctx, adapterProxy.Adapter(), params.IP)
	if err != nil {
		return nil, err
	}
	return &TailscalePingResult{LatencyMS: latency.Milliseconds()}, nil
}

func handleLogoutTailscale(params *TailscaleLogoutParams) error {
	runLock.Lock()
	defer runLock.Unlock()

	proxy, exists := tunnel.AllProxies()[params.Name]
	if !exists || proxy == nil || proxy.Type() != constant.Tailscale {
		return fmt.Errorf("Tailscale outbound %q not found", params.Name)
	}
	adapterProxy, ok := proxy.(*adapter.Proxy)
	if !ok {
		return fmt.Errorf("Tailscale outbound %q is unavailable", params.Name)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	return outbound.LogoutTailscale(ctx, adapterProxy.Adapter())
}

func getOverlayNetworkStatus(target OverlayNetworkTarget, proxy *adapter.Proxy, activate bool) OverlayNetworkStatus {
	status := OverlayNetworkStatus{
		Name:  target.Name,
		Kind:  target.Kind,
		State: overlayNetworkUnknown,
	}
	if target.Level != overlayNetworkSummary && target.Level != overlayNetworkDetails {
		status.State = overlayNetworkError
		status.Error = fmt.Sprintf("invalid overlay network detail level %q", target.Level)
		return status
	}
	if proxy == nil {
		status.State = overlayNetworkError
		status.Error = "overlay network outbound not found"
		return status
	}
	includeDetails := target.Level == overlayNetworkDetails
	switch target.Kind {
	case overlayNetworkTailscale:
		if proxy.Type() != constant.Tailscale {
			status.State = overlayNetworkError
			status.Error = fmt.Sprintf("proxy %q is not a Tailscale outbound", target.Name)
			return status
		}
		ctx, cancel := context.WithTimeout(context.Background(), 35*time.Second)
		defer cancel()
		tailscaleStatus, err := outbound.GetTailscaleStatus(ctx, proxy.Adapter(), includeDetails, activate)
		if err != nil {
			status.State = overlayNetworkError
			status.Error = err.Error()
			return status
		}
		return toTailscaleOverlayNetworkStatus(
			target,
			tailscaleStatus,
			outbound.TailscaleAuthKeyConfigured(proxy.Adapter()),
		)
	case overlayNetworkZeroTier:
		if proxy.Type() != constant.ZeroTier {
			status.State = overlayNetworkError
			status.Error = fmt.Sprintf("proxy %q is not a ZeroTier outbound", target.Name)
			return status
		}
		zeroTierStatus, err := outbound.GetZeroTierStatus(proxy.Adapter(), includeDetails, activate)
		if err != nil {
			status.State = overlayNetworkError
			status.Error = err.Error()
			return status
		}
		return toZeroTierOverlayNetworkStatus(target, zeroTierStatus)
	default:
		status.State = overlayNetworkError
		status.Error = fmt.Sprintf("unsupported overlay network kind %q", target.Kind)
		return status
	}
}

func toTailscaleOverlayNetworkStatus(target OverlayNetworkTarget, status *ipnstate.Status, authKeyConfigured bool) OverlayNetworkStatus {
	result := OverlayNetworkStatus{
		Name:     target.Name,
		Kind:     overlayNetworkTailscale,
		State:    tailscaleOverlayNetworkState(status.BackendState),
		RawState: status.BackendState,
		AuthURL:  status.AuthURL,
	}
	magicDNSSuffix := ""
	if status.CurrentTailnet != nil {
		result.NetworkName = status.CurrentTailnet.Name
		magicDNSSuffix = status.CurrentTailnet.MagicDNSSuffix
	}
	if target.Level != overlayNetworkDetails {
		return result
	}
	nodes := make([]TailscaleNode, 0, len(status.Peer)+1)
	if status.Self != nil {
		nodes = append(nodes, toTailscaleNode(status.Self, true))
	}
	for _, peer := range status.Peer {
		nodes = append(nodes, toTailscaleNode(peer, false))
	}
	slices.SortStableFunc(nodes, func(a, b TailscaleNode) int {
		if a.Self != b.Self {
			if a.Self {
				return -1
			}
			return 1
		}
		if a.Online != b.Online {
			if a.Online {
				return -1
			}
			return 1
		}
		return cmp.Compare(a.DNSName, b.DNSName)
	})
	result.Details = TailscaleNetworkDetails{
		MagicDNSSuffix:    magicDNSSuffix,
		AuthKeyConfigured: authKeyConfigured,
		Health:            append([]string{}, status.Health...),
		Nodes:             nodes,
	}
	return result
}

func tailscaleOverlayNetworkState(rawState string) OverlayNetworkState {
	switch rawState {
	case "NoState", "":
		return overlayNetworkUninitialized
	case "Running":
		return overlayNetworkConnected
	case "Starting":
		return overlayNetworkStarting
	case "NeedsLogin":
		return overlayNetworkNeedsLogin
	case "NeedsMachineAuth":
		return overlayNetworkNeedsApproval
	case "Stopped":
		return overlayNetworkStopped
	default:
		return overlayNetworkUnknown
	}
}

func toTailscaleNode(peer *ipnstate.PeerStatus, self bool) TailscaleNode {
	ips := make([]string, 0, len(peer.TailscaleIPs))
	for _, ip := range peer.TailscaleIPs {
		ips = append(ips, ip.String())
	}
	primaryRoutes := make([]string, 0)
	if peer.PrimaryRoutes != nil {
		peer.PrimaryRoutes.All()(func(_ int, prefix netip.Prefix) bool {
			primaryRoutes = append(primaryRoutes, prefix.String())
			return true
		})
	}
	tags := make([]string, 0)
	if peer.Tags != nil {
		peer.Tags.All()(func(_ int, tag string) bool {
			tags = append(tags, tag)
			return true
		})
	}
	publicKey := ""
	if !peer.PublicKey.IsZero() {
		publicKey = peer.PublicKey.String()
	}
	return TailscaleNode{
		ID:              string(peer.ID),
		PublicKey:       publicKey,
		HostName:        peer.HostName,
		DNSName:         peer.DNSName,
		OS:              peer.OS,
		IPs:             ips,
		Tags:            tags,
		PrimaryRoutes:   primaryRoutes,
		Endpoints:       append([]string{}, peer.Addrs...),
		CurrentEndpoint: peer.CurAddr,
		Relay:           peer.Relay,
		RxBytes:         peer.RxBytes,
		TxBytes:         peer.TxBytes,
		Online:          peer.Online,
		Active:          peer.Active,
		Self:            self,
		ExitNode:        peer.ExitNode,
		ExitNodeOption:  peer.ExitNodeOption,
		Expired:         peer.Expired,
		LastSeen:        nonZeroTime(peer.LastSeen),
		LastHandshake:   nonZeroTime(peer.LastHandshake),
		KeyExpiry:       peer.KeyExpiry,
	}
}

func nonZeroTime(value time.Time) *time.Time {
	if value.IsZero() {
		return nil
	}
	return &value
}

func toZeroTierOverlayNetworkStatus(target OverlayNetworkTarget, status outbound.ZeroTierStatus) OverlayNetworkStatus {
	result := OverlayNetworkStatus{
		Name:        target.Name,
		Kind:        overlayNetworkZeroTier,
		State:       zeroTierOverlayNetworkState(status.Status, status.Error),
		RawState:    status.Status,
		NetworkName: status.Network,
		AuthURL:     status.AuthURL,
		Error:       status.Error,
	}
	if target.Level != overlayNetworkDetails {
		return result
	}
	peers := make([]ZeroTierPeer, len(status.Peers))
	for index, peer := range status.Peers {
		peers[index] = ZeroTierPeer{
			Address:   peer.Address,
			Role:      peer.Role,
			Version:   peer.Version,
			Direct:    peer.Direct,
			Endpoints: peer.Endpoints,
			LatencyMS: peer.LatencyMS,
		}
	}
	result.Details = ZeroTierNetworkDetails{
		NetworkID: status.NetworkID,
		Node:      status.Node,
		Online:    status.Online,
		Addresses: status.Addresses,
		Routes:    status.Routes,
		DNS:       status.DNS,
		MTU:       status.MTU,
		Peers:     peers,
	}
	return result
}

func zeroTierOverlayNetworkState(rawState string, statusError string) OverlayNetworkState {
	if statusError != "" {
		return overlayNetworkError
	}
	switch rawState {
	case "":
		return overlayNetworkUninitialized
	case "ok":
		return overlayNetworkConnected
	case "requesting-configuration":
		return overlayNetworkStarting
	case "authentication-required":
		return overlayNetworkNeedsLogin
	case "stopped":
		return overlayNetworkStopped
	case "access-denied", "not-found":
		return overlayNetworkError
	default:
		return overlayNetworkUnknown
	}
}

func handleUpdateGeoData(geoType string) {
	go func() {
		switch geoType {
		case "MMDB":
			updater.UpdateMMDB()
			return
		case "ASN":
			updater.UpdateASN()
			return
		case "GEOIP":
			updater.UpdateGeoIp()
			return
		case "GEOSITE":
			updater.UpdateGeoSite()
			return
		}
	}()
}

func handleUpdateExternalProvider(providerName string, fn func(value string)) {
	go func() {
		runLock.Lock()
		externalProvider, exist := externalProviders[providerName]
		runLock.Unlock()
		if !exist {
			fn("external provider is not exist")
			return
		}
		err := externalProvider.Update()
		if err != nil {
			fn(err.Error())
			return
		}
		fn("")
	}()
}

func handleSideLoadExternalProvider(providerName string, data []byte, fn func(value string)) {
	go func() {
		runLock.Lock()
		defer runLock.Unlock()
		externalProvider, exist := externalProviders[providerName]
		if !exist {
			fn("external provider is not exist")
			return
		}
		err := sideUpdateExternalProvider(externalProvider, data)
		if err != nil {
			fn(err.Error())
			return
		}
		fn("")
	}()
}

func handleSuspend(suspended bool) bool {
	if suspended {
		tunnel.OnSuspend()
	} else {
		tunnel.OnRunning()
	}
	return true
}

func handleStartLogNotify() []StampedLogEvent {
	logNotifyMutex.Lock()
	defer logNotifyMutex.Unlock()
	logs := make([]StampedLogEvent, logNotifyLen)
	if logNotifyLen != 0 {
		for i := 0; i < logNotifyLen; i++ {
			index := (logNotifyStart + i) % maxCachedLogNotify
			logs[i] = logNotifyCache[index]
		}
	}
	logNotifyStart = 0
	logNotifyLen = 0
	logNotifyEnabled = true

	return logs
}

func handleStopLogNotify() {
	logNotifyMutex.Lock()
	defer logNotifyMutex.Unlock()
	logNotifyEnabled = false
}

func cacheLog(logData StampedLogEvent) {
	if logNotifyLen < maxCachedLogNotify {
		index := (logNotifyStart + logNotifyLen) % maxCachedLogNotify
		logNotifyCache[index] = logData
		logNotifyLen++
		return
	}
	logNotifyCache[logNotifyStart] = logData
	logNotifyStart = (logNotifyStart + 1) % maxCachedLogNotify
}

func handleStartRequestNotify() []*statistic.TrackerInfo {
	requestNotifyMutex.Lock()
	defer requestNotifyMutex.Unlock()

	requests := make([]*statistic.TrackerInfo, requestNotifyLen)
	for i := 0; i < requestNotifyLen; i++ {
		index := (requestNotifyStart + i) % maxCachedRequestNotify
		requests[i] = requestNotifyCache[index]
		requestNotifyCache[index] = nil
	}
	requestNotifyStart = 0
	requestNotifyLen = 0
	requestNotifyEnabled = true

	return requests
}

func handleStopRequestNotify() {
	requestNotifyMutex.Lock()
	defer requestNotifyMutex.Unlock()
	requestNotifyEnabled = false
}

func handleGetCountryCode(ip string, fn func(value string)) {
	go func() {
		runLock.Lock()
		defer runLock.Unlock()
		codes := mmdb.IPInstance().LookupCode(net.ParseIP(ip))
		if len(codes) == 0 {
			fn("")
			return
		}
		fn(codes[0])
	}()
}

func handleGetMemory(fn func(value uint64)) {
	go func() {
		var memStats runtime.MemStats
		runtime.ReadMemStats(&memStats)
		fn(memStats.StackInuse + memStats.HeapInuse + memStats.HeapIdle - memStats.HeapReleased)
	}()
}

func handleGetGoroutineCount(fn func(value int)) {
	go func() {
		fn(runtime.NumGoroutine())
	}()
}

func managedPathComponents(scope ManagedPathScope) ([]string, error) {
	switch scope {
	case profilesPathScope:
		return []string{"profiles"}, nil
	case providersPathScope:
		return []string{"profiles", "providers"}, nil
	case scriptsPathScope:
		return []string{"scripts"}, nil
	default:
		return nil, fmt.Errorf("invalid managed path scope: %s", scope)
	}
}

func resolveManagedPath(relativePath string) (string, error) {
	if relativePath == "" || relativePath == "." || !filepath.IsLocal(relativePath) {
		return "", fmt.Errorf("invalid managed relative path: %s", relativePath)
	}

	cleanPath := filepath.Clean(relativePath)
	if cleanPath == "." || !filepath.IsLocal(cleanPath) {
		return "", fmt.Errorf("invalid managed relative path: %s", relativePath)
	}
	return cleanPath, nil
}

func openManagedRoot(scope ManagedPathScope) (*os.Root, error) {
	components, err := managedPathComponents(scope)
	if err != nil {
		return nil, err
	}

	root, err := os.OpenRoot(constant.Path.HomeDir())
	if err != nil {
		return nil, err
	}
	for _, component := range components {
		// Open each fixed scope component from its verified parent. Comparing the
		// opened directory with a no-follow lookup rejects symlink/reparse roots
		// and detects replacements that race with OpenRoot.
		nextRoot, err := root.OpenRoot(component)
		if err != nil {
			_ = root.Close()
			return nil, err
		}
		openedInfo, err := nextRoot.Stat(".")
		if err != nil {
			_ = nextRoot.Close()
			_ = root.Close()
			return nil, err
		}
		pathInfo, err := root.Lstat(component)
		if err != nil {
			_ = nextRoot.Close()
			_ = root.Close()
			return nil, err
		}
		if !pathInfo.IsDir() || pathInfo.Mode()&os.ModeSymlink != 0 || !os.SameFile(openedInfo, pathInfo) {
			_ = nextRoot.Close()
			_ = root.Close()
			return nil, fmt.Errorf("managed path scope is not a stable directory: %s", scope)
		}
		_ = root.Close()
		root = nextRoot
	}
	return root, nil
}

func readManagedConfig(root *os.Root, path string) ([]byte, error) {
	file, err := root.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	fileInfo, err := file.Stat()
	if err != nil {
		return nil, err
	}
	if !fileInfo.Mode().IsRegular() {
		return nil, fmt.Errorf("config is not a regular file")
	}
	data, err := io.ReadAll(file)
	if err != nil {
		return nil, err
	}
	return data, nil
}

func handleGetProfileConfig(profileID int64) (*config.RawConfig, error) {
	if !isInit.Load() {
		return nil, fmt.Errorf("not initialized")
	}
	if profileID <= 0 {
		return nil, fmt.Errorf("invalid profile id: %d", profileID)
	}
	path, err := resolveManagedPath(strconv.FormatInt(profileID, 10) + ".yaml")
	if err != nil {
		return nil, err
	}
	root, err := openManagedRoot(profilesPathScope)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	bytes, err := readManagedConfig(root, path)
	if err != nil {
		return nil, err
	}
	prof, err := config.UnmarshalRawConfig(bytes)
	if err != nil {
		return nil, err
	}
	return prof, nil
}

func handleCrash() {
	panic("handle invoke crash")
}

func handleUpdateConfig(params *UpdateParams) string {
	updateConfig(params)
	return ""
}

// handleClearEffect derives the provider directory from a profile ID so the
// method cannot be used as a general-purpose privileged file deletion API.
func handleClearEffect(profileId int64, response MethodResponse) {
	go func() {
		if profileId <= 0 {
			response.success("invalid profile id")
			return
		}
		response.success(
			handleDeleteManagedPath(
				&DeleteManagedPathParams{
					Scope:        providersPathScope,
					RelativePath: strconv.FormatInt(profileId, 10),
				},
			),
		)
	}()
}

func handleDeleteManagedPath(params *DeleteManagedPathParams) string {
	if !isInit.Load() {
		return "not initialized"
	}
	path, err := resolveManagedPath(params.RelativePath)
	if err != nil {
		return err.Error()
	}
	root, err := openManagedRoot(params.Scope)
	if err != nil {
		if os.IsNotExist(err) {
			return ""
		}
		return err.Error()
	}
	defer root.Close()
	err = root.RemoveAll(path)
	if err != nil {
		return err.Error()
	}
	return ""
}

func handleSetupConfig(params *SetupParams) string {
	if !isInit.Load() {
		return "not initialized"
	}
	err := applyConfig(params)
	if err != nil {
		return err.Error()
	}
	return ""
}

func init() {
	logSubscriber = log.Subscribe()
	go func() {
		for logData := range logSubscriber {
			if logData.LogLevel < log.Level() {
				continue
			}
			stampedLog := StampedLogEvent{
				LogLevel: logData.LogLevel,
				Payload:  logData.Payload,
				Time:     time.Now().UnixMilli(),
			}
			writeSystemLog(logData.LogLevel.String(), logData.Payload)
			logNotifyMutex.Lock()
			if !logNotifyEnabled {
				cacheLog(stampedLog)
				logNotifyMutex.Unlock()
				continue
			}
			logNotifyMutex.Unlock()
			sendMessage(Message{
				Type: LogMessage,
				Data: stampedLog,
			})
		}
	}()
	adapter.UrlTestHook = func(url string, name string, delay uint16) {
		delayData := &Delay{
			Url:  url,
			Name: name,
		}
		if delay == 0 {
			delayData.Value = -1
		} else {
			delayData.Value = int32(delay)
		}
		sendMessage(Message{
			Type: DelayMessage,
			Data: delayData,
		})
	}
	statistic.DefaultRequestNotify = func(c statistic.Tracker) {
		requestNotifyMutex.Lock()
		if !requestNotifyEnabled {
			defer requestNotifyMutex.Unlock()
			request := c.Info()
			if requestNotifyLen < maxCachedRequestNotify {
				index := (requestNotifyStart + requestNotifyLen) % maxCachedRequestNotify
				requestNotifyCache[index] = request
				requestNotifyLen++
				return
			}
			requestNotifyCache[requestNotifyStart] = request
			requestNotifyStart = (requestNotifyStart + 1) % maxCachedRequestNotify
			return
		}
		requestNotifyMutex.Unlock()
		sendMessage(Message{
			Type: RequestMessage,
			Data: c,
		})
	}
	executor.DefaultProviderLoadedHook = func(providerName string) {
		sendMessage(Message{
			Type: LoadedMessage,
			Data: providerName,
		})
	}
	updater.GeoUpdateHook = func(geoType string, updating bool, skipped bool, updateErr error) {
		status := GeoUpdateStatus{
			Type:     geoType,
			Updating: updating,
			Skipped:  skipped,
		}
		if updateErr != nil {
			status.Error = updateErr.Error()
		}
		sendMessage(Message{
			Type: GeoUpdateMessage,
			Data: status,
		})
	}
}
