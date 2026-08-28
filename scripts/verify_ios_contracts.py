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
    present=["invokeMethod<String>('getNativeLogs')"],
)

if failures:
    for f in failures:
        print('FAIL ' + f)
    sys.exit(1)

print('IOS_ROOT_CAUSE_CONTRACT_PASS')
