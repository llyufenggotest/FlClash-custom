from pathlib import Path
import sys

failures = []


def check(path, present=(), absent=()):
    text = Path(path).read_text(encoding='utf-8', errors='replace')
    for n in present:
        if n not in text:
            failures.append('%s missing %r' % (path, n))
    for n in absent:
        if n in text:
            failures.append('%s should not contain %r' % (path, n))


def check_order(path, *needles):
    """Assert data-flow ordering, not just disconnected token presence."""
    text = Path(path).read_text(encoding='utf-8', errors='replace')
    cursor = 0
    for needle in needles:
        position = text.find(needle, cursor)
        if position < 0:
            failures.append('%s missing ordered %r after offset %d' % (path, needle, cursor))
            return
        cursor = position + len(needle)


check(
    'core/dns_listener_default.go',
    present=[
        '//go:build !(ios && !with_low_memory)',
        'disableDNSListener = false',
        'secondaryCacheFileName = ""',
    ],
)

check(
    'core/dns_listener_ios_app.go',
    present=[
        '//go:build ios && !with_low_memory',
        'disableDNSListener = true',
        'network-extension',
        'cache-app.db',
    ],
)

check(
    'core/common.go',
    present=['applyDNSListenerOwnership(nextConfig)', 'cfg.DNS.Listen = ""', 'releaseReloadMemory()', 'debug.FreeOSMemory()', 'features.WithLowMemory'],
)

check(
    'core/hub.go',
    present=[
        'cacheName := secondaryCacheFileName',
        'if features.IOS && !features.WithLowMemory {',
        'runnerCacheFileName(params.HomeDir, processHome)',
        'private path validation failed',
        'constant.SetCacheFileName(cacheName)',
    ],
    absent=['constant.SetCacheFileName(secondaryCacheFileName)'],
)
check(
    'core/runner_cache_path.go',
    present=[
        'filepath.IsAbs(processHome)', 'filepath.IsAbs(sharedHome)',
        'filepath.EvalSymlinks(processHome)',
        '/Containers/Data/Application/',
        '"Library", "Application Support", "RunnerCore"',
        'filepath.EvalSymlinks(dir)', 'filepath.Rel(privateHome, resolved)',
        'Runner cache directory escapes private data container',
        'os.Lstat(cachePath)', 'info.Mode().IsRegular()',
        'filepath.Rel(filepath.Clean(sharedHome), cachePath)',
    ],
)

check(
    'core/mihomo/constant/path.go',
    present=['func SetCacheFileName', 'p.cacheFileName()'],
)

for swift in (
    'ios/NECore/NativeDiagnosticLog.swift',
    'ios/Runner/ServiceChannel.swift',
):
    check(
        swift,
        present=[
            'static func retainedTail',
            'firstIndex(of: 0x0A)',
            'maxBytes: UInt64 = 4 * 1024 * 1024',
        ],
        absent=['data.suffix(min(data.count'],
    )

check(
    'ios/NECore/NativeDiagnosticLog.swift',
    present=['caseInsensitiveCompare("debug")', '[REDACTED]'],
)

check(
    'ios/Runner/ServiceChannel.swift',
    present=['if call.method != "invokeMethod"', 'getNativeLogs'],
)

check(
    'ios/NECore/PacketTunnelProvider.swift',
    present=[
        'startup_failure phase=vpn_options_missing',
        'startup_failure phase=set_network_settings_failed',
        'startup_failure phase=tunnel_fd_missing',
        'startup_failure phase=quick_setup_failed',
        'startup_failure phase=start_tun_failed',
        'rollbackPartialStart',
        'resourceHeartbeat.start()',
        'resourceHeartbeat.stop()',
        'final class CoreShutdownCleanupGate',
        'static let providerStopDeadline: TimeInterval = 4',
    ],
)
# Cleanup is a two-signal join: even an inline shutdown callback cannot resolve
# the barrier until stopTun has returned. The gate also retains the callback for
# asynchronous delivery and deduplicates repeated callback/stop signals.
check_order(
    'ios/NECore/PacketTunnelProvider.swift',
    'let cleanupGate = CoreShutdownCleanupGate(completion: completion)',
    'NECoreBridge.invokeMethod(request)',
    'cleanupGate.receiveShutdownResult(success)',
    'NECoreBridge.stopTun()',
    'cleanupGate.didStopTun()',
)
check_order(
    'ios/NECore/PacketTunnelProvider.swift',
    'guard stopTunFinished, let shutdownResult else { return nil }',
    'resolved = true',
    'if let resolvedResult { completion(resolvedResult) }',
)

check(
    'ios/NECore/NativeResourceHeartbeat.swift',
    present=[
        'memory_pressure_warning',
        'footprintWarningMB',
        'phys_footprint',
        'footprint_mb=',
    ],
)

check(
    'ios/Runner/Tunnel/TunnelCoordinator.swift',
    present=[
        'connectTimeout: TimeInterval = 30',
        'startup still pending after timeout',
        'settle still pending after timeout',
    ],
    absent=['failed start requested cleanup stop', 'cleanUpFailedStart'],
)

check(
    'ios/Runner/Tunnel/TunnelManagerStore.swift',
    present=['loadTimeout: TimeInterval = 15'],
)

check(
    'ios/Runner/Tunnel/TunnelController.swift',
    present=[
        'providerMessageTimeout',
        'provider message begin seq=',
        'provider message timeout seq=',
        'ProviderMessageWaiter',
    ],
)

check(
    'lib/providers/app.dart',
    present=[
        '===== iOS Runner / Network Extension =====',
        'getNativeLogs',
        "import 'package:fl_clash/plugins/service.dart'",
    ],
)

check(
    'lib/plugins/service.dart',
    present=[
        "invokeMethod<String>('getNativeLogs')",
        "invokeMethod<bool>('clearNativeLogs')",
    ],
)

# --- vpnOptions cross-process startup transport -----------------------------
# Device trace 2026-08-29 (x365): Runner logged saveSharedState bytes=868 with a
# real attempt ID, then NECore failed four times with attempt=none and
# startup_failure phase=vpn_options_missing. UserDefaults was not visible to the
# freshly launched extension even though the container file was writable.

check(
    'ios/Runner/Storage/SharedStateStore.swift',
    present=[
        'func commitSharedStateSnapshot',
        'func sharedStateSnapshotURL',
        'func makeTunnelStartOptions',
        'options: .atomic',
    ],
)

check(
    'ios/Runner/Tunnel/TunnelManagerStore.swift',
    present=[
        'func prepareTunnelStartPayload',
        'TunnelStartPayload',
        'snapshotCommitted',
    ],
)

check(
    'ios/Runner/Tunnel/TunnelCoordinator.swift',
    present=[
        'prepareTunnelStartPayload',
        'startVPNTunnel(options:',
        'snapshot=',
    ],
)

check(
    'ios/NECore/PacketTunnelSharedStateStore.swift',
    present=[
        'enum SharedStateSource',
        'case options',
        'case defaults',
        'case snapshot',
        'func adoptStartOptions',
        'func loadVPNOptionsResult',
        'suiteUnavailable = "suite_unavailable"',
        'decodeIfPresent',
    ],
    absent=['try container.decode(Int.self, forKey: .port)'],
)

check(
    'ios/NECore/PacketTunnelProvider.swift',
    present=[
        'adoptStartOptions(options)',
        'loadVPNOptionsResult()',
        'shared_state source=',
        'startup_failure phase=vpn_options_missing reason=',
    ],
)

# --- extension memory budget ------------------------------------------------
# Same trace: footprint peaked at 47 MB against a ~50 MB packet-tunnel limit and
# each crossing was followed by "tunnel stopped externally". FreeOSMemory on
# reload alone was not enough, so the peak itself has to come down.

check(
    'core/memory_budget_ios_extension.go',
    present=[
        '//go:build ios && with_low_memory',
        'delayBatchConcurrency = 8',
    ],
)

check(
    'core/memory_budget_default.go',
    present=[
        '//go:build !(ios && with_low_memory)',
        'delayBatchConcurrency = 50',
    ],
)

# Manual requests are bounded before goroutine creation; actual URLTest work
# shares one budget across manual, group and provider-health-check entry points.
# Contracts moved to build-tag-specific scheduler and to the new ApplyConfig/preflight flow.
check('core/delay_scheduler_extension.go', present=['manualProbes = probelimit.New(delayBatchConcurrency*5, 0)', 'manualProbes.CancelAll()', 'probelimit.Default.CancelAll()', 'manualProbes.Acquire(ctx)', 'defer release()'])
check('core/delay_scheduler_default.go', present=['manualProbeSlots = make(chan struct{}, delayBatchConcurrency)', 'manualProbeCtx', 'manualProbeStop()', 'manualProbeGenerationCurrent'])
check('core/mihomo/adapter/adapter.go', present=['ctx, release, err = probelimit.Default.Acquire(ctx)', 'if probelimit.Enabled && ctx.Err() == context.Canceled {'])
check('core/mihomo/hub/executor/executor.go', present=['loadProvider(providers)'])
check('core/mihomo/rules/provider/lowmem_budget_lowmem.go', present=['maxLowMemoryRuleCount = extensionRawRuleBudget'])
check('core/lib.go', present=['func handleStopTun() {\n\tcancelDelayTests()'])
check(
    'core/hub.go',
    present=['func handleAsyncTestDelay(', 'request := *params', 'proxy.URLTest(ctx, testUrl, expectedStatus)'],
    absent=['mBatch.Go', 'batchKey :='],
)
check(
    'core/mihomo/common/probelimit/limiter.go',
    present=[
        'Default = New(activeLimit, activeLimit*4)',
        'admitted: make(chan struct{}, active+queued)',
        'return nil, nil, ErrBusy', 'context.AfterFunc(l.generation, cancel)',
        'case <-ctx.Done():', 'var once sync.Once',
        'once.Do(func() { <-l.active; cleanup() })',
    ],
)
check(
    'core/mihomo/adapter/adapter.go',
    present=[
        'ctx, release, err = probelimit.Default.Acquire(ctx)',
        'defer release()', 'if probelimit.Enabled && ctx.Err() == context.Canceled {',
        'p.historyMu.Lock()', 'if len(p.extraOrder) >= 16 {',
        'p.extra.Delete(p.extraOrder[0])',
    ],
)
check(
    'core/delay_scheduler_test.go',
    present=[
        'func TestManualProbeOverloadRespondsOnce(',
        'func TestManualProbeExpiredRespondsOnce(',
        'func TestStopCancelsProbeGenerations(',
    ],
)
check(
    'core/mihomo/common/probelimit/limiter_test.go',
    present=[
        'func TestBoundCancelAndReuse(', 'func TestQueuedDeadline(',
        'func TestCancelAllQueued(',
    ],
)

check(
    'ios/NECore/NativeResourceHeartbeat.swift',
    present=[
        # Threshold values are asserted in the admission-control section below,
        # which owns the current numbers.
        'footprintWarningMB =',
        'footprintReclaimMB =',
        'memory_pressure_reclaim ',
        'memory_pressure_reclaimed ',
        'static func shouldReclaim',
        'NECoreBridge.releaseMemory()',
    ],
)

check('ios/NECore/NECoreBridge.h', present=['+ (void)releaseMemory;'])
check('ios/NECore/NECoreBridge.m', present=['forceGC();'])

# --- iOS profile sanitizer --------------------------------------------------
# The shipped profiles carry full desktop global config: inbound ports iOS never
# consumes, an external-controller HTTP API with a plaintext secret, a dns.listen
# that fought the other process for port 1053, plus Oppa pre-connect=8 over 180
# nodes and 60s url-test sweeps.

check(
    'lib/common/ios_profile_budget.dart',
    present=[
        'iosRemovedGlobalKeys',
        'iosRemovedDnsKeys',
        'iosPreConnectCap = 2',
        'iosMinHealthCheckInterval = 300',
        'iosMinRuleProviderInterval = 604800',
        "config['find-process-mode'] = 'off'",
        "config['tcp-concurrent'] = false",
        'sanitizeProfileForIOS',
    ],
    # mixed-port must survive: NEProxySettings and checkIp both dial it.
    absent=["'mixed-port',"],
)

check(
    'lib/common/common.dart',
    present=["export 'ios_profile_budget.dart';"],
)

check(
    'lib/common/task.dart',
    present=['sanitizeProfileForIOS(finalConfig)', 'isIOS: system.isIOS', 'required bool isIOS'],
)

check(
    '.github/workflows/build.yaml',
    present=[
        'flutter test --reporter expanded --coverage',
    ],
)

# --- redundant config reload on foreground return ---------------------------
# Device trace 2026-08-29 15:18: the extension ran "Start initial configuration"
# five times in four minutes (05:31:55, 05:32:53, 05:33:21, 05:34:25, 05:35:31),
# each time reloading geodata, rebuilding the 111826-record GeoSite matcher and
# re-fetching 20 remote rule-providers. Provider messages stalled during those
# windows: 51 timeouts (p90 6627ms against an 8s budget) and 45 empty replies,
# which is exactly the network_extension_timeout dialog and the empty proxies
# page. Trigger: Runner emits start on every invalid -> connected transition and
# _setupConfig honoured the forced apply because its applied-config fingerprint
# lived only in memory, so it was always null after a relaunch.

check(
    'lib/common/constant.dart',
    present=["const appliedConfigMd5Key = 'applied_config_md5'"],
)

check(
    'lib/common/preferences.dart',
    present=[
        'Future<String?> getAppliedConfigMd5()',
        'Future<void> setAppliedConfigMd5(',
        'appliedConfigMd5Key',
    ],
)

check(
    'lib/providers/actions/setup.dart',
    present=[
        'await preferences.getAppliedConfigMd5()',
        'await preferences.setAppliedConfigMd5(appliedYamlMd5)',
        'await preferences.setAppliedConfigMd5(null)',
        'final diskMatches =',
        'await configFile.exists()',
        # Asserted as separate conditions rather than one literal line: the
        # earlier single-string form broke as soon as a new guard joined the
        # expression, which fails the build without anything being wrong.
        'final skipRedundantReload =',
        'matchesAppliedConfig',
        '(!force || (system.isIOS && _isRunning))',
        # A subscription switch must never take the fast path: two profiles can
        # render identical YAML, and the core still has to rebuild so the stale
        # providers are closed (core/mihomo tunnel.UpdateProxies).
        '!profileSwitched',
        'if (skipRedundantReload) {',
        'await preloadInvoke?.call();',
    ],
    # The skip must never be unconditional: Android and desktop run the core in
    # process, where a forced apply is the only way to load config at all.
    absent=['matchesAppliedConfig && _isRunning', 'skipRedundantReload = true'],
)

# --- jetsam kill: delay-probe admission control ------------------------------
# Device traces 2026-08-29 22:46 (two exports) pinned the death line. Four
# consecutive tunnel lives logged a final heartbeat of 43, 48, 47 and 47 MB
# phys_footprint and were killed on the next tick, so the ceiling is ~48 MB, not
# the assumed 50. Cause: the app allowed 50 concurrent delay probes while the
# extension's Go core caps delayBatchConcurrency at 8 under with_low_memory, so
# 42 surplus probes queued inside the memory-constrained process. One trace shows
# 56 provider messages issued in one second, 65 in flight at peak, footprint
# 32 -> 47 MB in three seconds. Queue pressure pushed provider-message p50 to
# 2719 ms against the 8 s budget: 51 timeouts and 45 empty replies.

check(
    'lib/common/constant.dart',
    present=[
        'const _maxConcurrentDelayTestsIOS = 8',
        'const _maxConcurrentDelayTestsDefault = 50',
        'final maxConcurrentDelayTests = system.isIOS',
    ],
    # A single flat const is what caused the mismatch in the first place.
    absent=['const maxConcurrentDelayTests = 50', 'const maxConcurrentDelayTests = 8'],
)

check(
    'lib/providers/actions/proxies.dart',
    present=[
        'static final _delayTestConcurrency = maxConcurrentDelayTests',
        '_runningDelayTests < _delayTestConcurrency',
    ],
    # `static const` cannot hold a platform-resolved value.
    absent=['static const _delayTestConcurrency'],
)

check(
    'core/memory_budget_ios_extension.go',
    present=['const delayBatchConcurrency = 8'],
)

check(
    'ios/Runner/Tunnel/TunnelController.swift',
    present=[
        'private let maxInFlightProviderMessages = 8',
        'private var inFlightProviderMessages = 0',
        'func acquireProviderMessageSlot() async',
        'func releaseProviderMessageSlot()',
        'await acquireProviderMessageSlot()',
        'defer { releaseProviderMessageSlot() }',
        # Admission control is meant to make this budget hold, not be swapped
        # for a longer one.
        'providerMessageTimeout: TimeInterval = 8',
    ],
)

check(
    'ios/NECore/NativeResourceHeartbeat.swift',
    present=[
        'footprintWarningMB = 30',
        'footprintReclaimMB = 38',
        # A lower reclaim threshold must not become a per-second stall.
        'reclaimCooldown: TimeInterval = 15',
    ],
    absent=['footprintWarningMB = 35', 'footprintReclaimMB = 42'],
)

check(
    '.github/workflows/build.yaml',
    present=['flutter test --reporter expanded --coverage'],
)

# --- honest start result + non-blocking first rule-provider fetch ------------
# Device trace 2026-08-29 23:39 produced two independent failures:
#
# 1. Attempt 0fa73135 logged `TUN: dup fd: bad file descriptor` and then
#    `startTun result=true` in the same second. `startTUN` ended in a literal
#    `return true`, so Swift never ran rollbackPartialStart and the tunnel sat in
#    "connected" with no data path -- the user's "Oppa loses its configuration".
#
# 2. Oppa's quickSetup took 24-25s while all 24 remote rule providers failed DNS.
#    Config parsing itself finished in 66ms; the rest was waiting for providers
#    that cannot resolve until the tunnel exists, while applyConfig held the
#    `runLock` that startTUN also needs. Chicken-and-egg: "connected, no network".

check(
    'core/lib.go',
    present=[
        'func (th *TunHandler) start(fd int, options t.Options) bool',
        'func handleStartTun(callback unsafe.Pointer, fd int, options t.Options) bool',
        'started := handleStartTun(callback, int(fd), options)',
        'return started',
        'TUN: refusing to start with fd=0',
    ],
    # The literal success that hid a dead data path.
    absent=['\thandleStartTun(callback, int(fd), options)\n'],
)

check(
    'core/mihomo/hub/executor/executor.go',
    present=[
        'loadRuleProviders(cfg.RuleProviders)',
        'func loadRuleProviders[T P.Provider]',
        'loadProvider(cfg.Providers)',
    ],
    absent=['loadProvider(cfg.RuleProviders)'],
)

# The deferral is build-tagged so only the Network Extension changes behaviour.
check(
    'core/mihomo/hub/executor/rule_provider_defer_ios_lowmem.go',
    present=[
        '//go:build ios && with_low_memory',
        'deferRuleProviderInitial = true',
    ],
)

check(
    'core/mihomo/hub/executor/rule_provider_defer_default.go',
    present=[
        '//go:build !(ios && with_low_memory)',
        'deferRuleProviderInitial = false',
    ],
)

check(
    '.github/workflows/ios-five-protocol.yaml',
    present=['go test ./ -run \'TestStartTunReportsRealResult|TestRuleProviderFirstFetch\''],
)

# --- ASN.mmdb must never be mmapped inside the extension -------------------
# iOS charges file-backed mmap pages to phys_footprint. GeoLite2-ASN.mmdb is
# ~20 MB of a ~50 MB budget, and low-memory builds disable ASN rules anyway
# (geodata.InitASN stores asnEnable=false), so the mapping bought nothing and
# cost the extension its life. Two independent guards, both pinned here.
check(
    'core/mihomo/component/mmdb/mmdb.go',
    present=[
        'if !asnMappingAllowed {',
        'return ASNReader{}',
    ],
)

check(
    'core/mihomo/component/mmdb/asn_mapping_lowmem.go',
    present=[
        '//go:build with_low_memory',
        'asnMappingAllowed = false',
    ],
)

check(
    'core/mihomo/component/mmdb/asn_mapping_default.go',
    present=[
        '//go:build !with_low_memory',
        'asnMappingAllowed = true',
    ],
)

check(
    'core/mihomo/rules/common/ipasn.go',
    present=[
        # InitASN returns nil while disabling the feature; the rule must still
        # be refused so its first Match cannot trigger the mapping.
        'if !geodata.ASNEnable() {',
        'ASN database is disabled on this build',
    ],
)

check(
    # Callers must tolerate the unmapped reader instead of dereferencing nil.
    'core/mihomo/component/mmdb/reader.go',
    present=['if r.Reader == nil {'],
)

check(
    'core/mihomo/component/updater/update_geo.go',
    present=['if reader := mmdb.ASNInstance().Reader; reader != nil {'],
    # The unguarded close would panic once the reader can be nil.
    absent=['mmdb.ASNInstance().Reader.Close()'],
)

check(
    '.github/workflows/ios-five-protocol.yaml',
    present=['go test -tags with_low_memory ./component/mmdb/ ./rules/common/ -run ASN'],
)

# --- Proxy server addresses must never re-enter the tunnel -----------------
# The app process probes every node (delay tests, IP checks) with ordinary
# sockets, so the TUN captures them and the extension's core routes them. With a
# domain-only ruleset they fall through to MATCH and get dialled through a proxy:
# "connect to node_X" tunneled into node_Y. One subscription with 137 distinct
# server IPs turned that into a self-inflicted connection flood that killed the
# extension in ~3s. Pinning server addresses to DIRECT breaks the loop.
check(
    'core/mihomo/config/config.go',
    present=['config.Rules = prependProxyServerBypassRules(rules, proxies)'],
    # The raw assignment would leave the loop open.
    absent=['\tconfig.Rules = rules\n'],
)

check(
    'core/mihomo/config/proxy_server_bypass.go',
    present=[
        'func prependProxyServerBypassRules(',
        'if !proxyServerBypassEnabled {',
        # Must win over whatever the subscription ships, hence prepend.
        'return append(bypass, rules...)',
        # A rule naming a missing adapter would be a silent black hole.
        'if _, ok := proxies["DIRECT"]; !ok {',
        # No DNS round trip while the tunnel is still coming up.
        'RC.WithIPCIDRNoResolve(true)',
    ],
)

check(
    'core/mihomo/config/proxy_server_bypass_lowmem.go',
    present=[
        '//go:build with_low_memory',
        'proxyServerBypassEnabled = true',
    ],
)

check(
    'core/mihomo/config/proxy_server_bypass_default.go',
    present=[
        '//go:build !with_low_memory',
        'proxyServerBypassEnabled = false',
    ],
)

check(
    '.github/workflows/ios-five-protocol.yaml',
    present=['go test -tags with_low_memory ./config/ -run TestProxyServerBypass'],
)

# The end-to-end guard: parse each real subscription and assert no proxy server
# would be dialled through a proxy. Lives in package main because only there is
# hub/executor's temporaryUpdateGeneral linkname satisfied.
check(
    'core/ios_routing_loop_contract_test.go',
    present=[
        '//go:build with_low_memory',
        'func TestProxyServersNeverReEnterTunnel(',
        'func TestBypassRulesArePrepended(',
        'func TestBypassDoesNotHijackOrdinaryTraffic(',
    ],
)

# Round 12: the extension must never build a matcher for a huge rule set.
# NewDomainSet materialises and sorts every domain; measured on BanAD (187,945
# rules) that peaks at ~190 MB inside a ~50 MB jetsam budget, and the peak is
# independent of GOMEMLIMIT because that limit is soft. The MRS sidecar carries
# the finished bitmap instead (~18 MB), so no rules have to be dropped.
check(
    'core/mihomo/rules/provider/lowmem_budget_lowmem.go',
    present=['//go:build with_low_memory', 'maxLowMemoryRuleCount = extensionRawRuleBudget'],
)
check(
    'core/mihomo/rules/provider/lowmem_budget_default.go',
    present=['//go:build !with_low_memory', 'maxLowMemoryRuleCount = 0'],
)
check(
    'core/mihomo/rules/provider/mrs_sidecar.go',
    present=[
        'func loadFromSidecar(path string, source []byte, behavior P.RuleBehavior)',
        'func writeSidecar(vehiclePath string, source []byte, behavior P.RuleBehavior, strategy ruleStrategy)',
        'const sidecarMagic = "MRS-SC02"',
        'const sidecarHeaderSize = len(sidecarMagic) + 2*sha256.Size',
        'len(buf) < sidecarHeaderSize',
        'string(buf[:len(sidecarMagic)]) != sidecarMagic',
        'sourceHash := sha256.Sum256(source)',
        'payload := buf[sidecarHeaderSize:]',
        'payloadHash := sha256.Sum256(payload)',
        '!bytes.Equal(buf[len(sidecarMagic):len(sidecarMagic)+sha256.Size], sourceHash[:])',
        '!bytes.Equal(buf[len(sidecarMagic)+sha256.Size:sidecarHeaderSize], payloadHash[:])',
        'rulesMrsParse(payload, newStrategy(behavior, nil))',
        'envelope.Write(sourceHash[:])', 'envelope.Write(payloadHash[:])',
        'envelope.Write(payload.Bytes())',
        'os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".*.tmp")',
        'defer os.Remove(tmp.Name())',
        'tmp.Write(envelope.Bytes())', 'tmp.Sync()', 'tmp.Close()',
        'os.Rename(tmp.Name(), path)',
    ],
    absent=['func sidecarUsable(', '.ModTime()', 'os.Stat(', 'path + ".tmp"'],
)
# The sidecar must be tried BEFORE the raw parse on the capped build, and
# written only on an uncapped one.
check(
    'core/mihomo/rules/provider/provider.go',
    present=[
        'if maxLowMemoryRuleCount > 0 && format != P.MrsRule {',
        'loadFromSidecarBytes(sidecarSnapshot, bytes, behavior)',
        'if maxLowMemoryRuleCount == 0 && format != P.MrsRule {',
        'writeSidecar(vehicle.Path(), bytes, behavior, strategy)',
    ],
)
# The rule-count cap must gate the TRIE path only. Capping the MRS reader would
# reject exactly the artifact that makes the big lists affordable, which is a
# silent regression to the rules-dropped behaviour.
check(
    'core/mihomo/rules/provider/mrs_reader.go',
    absent=['ErrRuleSetTooLarge'],
)
check(
    'core/mihomo/rules/provider/mrs_sidecar_test.go',
    present=[
        'func TestSidecarRoundTripsEveryRule(',
        'func TestCappedBuildLoadsOversizedListFromSidecar(',
        'func TestStaleSidecarIsRefused(',
        'func TestCorruptSidecarErrors(',
    ],
)

# These remain source contracts, not a substitute for running the Go behavior
# suites in default and with_low_memory builds or measuring a physical device.
check(
    'core/mihomo/rules/provider/mrs_freshness_test.go',
    present=[
        'func TestSidecarSurvivesIdenticalRawTouch(',
        'func TestSidecarRejectsDifferentParserInput(',
        'func TestSidecarRejectsPayloadCorruptionAndWrongBehavior(',
        'func TestFetcherFirstDownloadAndChangedDownload(',
        'same-size same-mtime changed source accepted',
        'errors.Is(err, ErrRuleSetTooLarge)',
        'injected cache write failure',
        'assertDomainRules(t, rp.strategy, "host", 12000)',
        'assertDomainRules(t, second.strategy, "next", 12000)',
        'for i := 0; i < n; i++ {',
        's.Match(metadataForHost(',
    ],
)
check_order(
    'core/hub.go', 'func handleAsyncTestDelay(', 'request := *params',
    'scheduleDelayTest(', 'proxy.URLTest(', 'fn(delayData)',
)
check_order(
    'core/hub.go', 'runnerCacheFileName(params.HomeDir, processHome)',
    'if err != nil {', 'return false', 'constant.SetHomeDir(params.HomeDir)',
    'constant.SetCacheFileName(cacheName)',
)
check_order(
    'core/mihomo/rules/provider/provider.go',
    'if maxLowMemoryRuleCount > 0 && format != P.MrsRule {',
    'sidecarSnapshot, sidecarErr = os.ReadFile(sidecarPath(vehicle.Path()))',
    'loadFromSidecarBytes(sidecarSnapshot, bytes, behavior)',
    'if err == nil {', 'return loadedRuleStrategy{',
    'strategy, err := rulesParse(bytes,', 'if err != nil {', 'return loadedRuleStrategy{}, err',
    'if maxLowMemoryRuleCount == 0 && format != P.MrsRule {',
    'writeSidecar(vehicle.Path(), bytes, behavior, strategy)',
)
check_order(
    'core/mihomo/rules/provider/mrs_sidecar.go',
    'buf, err := os.ReadFile(path)', 'sourceHash := sha256.Sum256(source)',
    'payload := buf[sidecarHeaderSize:]', 'payloadHash := sha256.Sum256(payload)',
    'return nil, fmt.Errorf("MRS sidecar content hash mismatch;',
    'return rulesMrsParse(payload, newStrategy(behavior, nil))',
)
check_order(
    'core/mihomo/rules/provider/mrs_sidecar.go',
    'os.CreateTemp(', 'tmp.Write(envelope.Bytes())', 'tmp.Sync()',
    'tmp.Close()', 'if err == nil {', 'os.Rename(tmp.Name(), path)',
)
sidecar_source = Path('core/mihomo/rules/provider/mrs_sidecar.go').read_text(encoding='utf-8')
if sidecar_source.count('os.ReadFile(') != 1:
    failures.append('mrs_sidecar.go must validate and parse a single read buffer')

if failures:
    for f in failures:
        print('FAIL ' + f)
    sys.exit(1)

print('IOS_ROOT_CAUSE_CONTRACT_PASS')
