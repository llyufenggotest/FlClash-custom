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
    present=[
        'applyDNSListenerOwnership(currentConfig)',
        'cfg.DNS.Listen = ""',
        'releaseReloadMemory()',
        'debug.FreeOSMemory()',
        'features.WithLowMemory',
    ],
)

check(
    'core/hub.go',
    present=['constant.SetCacheFileName(secondaryCacheFileName)'],
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
    ],
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
        'replaceItemAtomically',
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

check(
    'core/common.go',
    present=['batch.WithConcurrencyNum[bool](delayBatchConcurrency)'],
    absent=['batch.WithConcurrencyNum[bool](50)'],
)

check(
    'ios/NECore/NativeResourceHeartbeat.swift',
    present=[
        'footprintWarningMB = 35',
        'footprintReclaimMB = 42',
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
    present=['sanitizeProfileForIOS(finalConfig)', 'if (system.isIOS)'],
)

check(
    '.github/workflows/ios-five-protocol.yaml',
    present=['flutter test test/ios_profile_budget_test.dart'],
)

if failures:
    for f in failures:
        print('FAIL ' + f)
    sys.exit(1)

print('IOS_ROOT_CAUSE_CONTRACT_PASS')
