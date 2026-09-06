#!/usr/bin/env python3
"""macOS CI: compile and execute the actual production RPC receiver.
No Python transport model or source-string assertions are substituted.
"""
import pathlib
import shutil
import subprocess
import tempfile
import sys

root = pathlib.Path(__file__).resolve().parents[2]
swiftc = shutil.which('swiftc')
if not swiftc or sys.platform != 'darwin':
    sys.exit('BLOCKED: requires macOS swiftc (Foundation + Darwin directory notifications)')
with tempfile.TemporaryDirectory(prefix='ios-rpc-') as directory:
    executable = pathlib.Path(directory) / 'rpc-tests'
    subprocess.run([swiftc, '-swift-version', '5', str(root / 'ios/NECore/ProviderMessageMailbox.swift'),
                    str(root / 'test/ios_rpc/main.swift'), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
    # Extract verbatim production state units, not a test transport model.
    units = []
    for path in ['ios/Runner/ServiceChannel.swift', 'ios/Runner/Core/CoreMessageRouter.swift',
                 'ios/NECore/PacketTunnelProvider.swift']:
        source = (root / path).read_text(encoding='utf-8')
        units.append(source.split('// BEGIN RPC LIFECYCLE UNIT', 1)[1].split('// END RPC LIFECYCLE UNIT', 1)[0])
    production = pathlib.Path(directory) / 'Lifecycle.swift'
    production.write_text(
        'import Foundation\n'
        + '\n'.join(units)
        + '\n'
        + (root / 'ios/Runner/Core/CoreNotificationCoordinator.swift').read_text(encoding='utf-8')
        + '\n'
        + (root / 'test/ios_rpc/lifecycle.swift').read_text(encoding='utf-8'),
        encoding='utf-8',
    )
    # Keep the lifecycle units and their executable test in one compilation
    # unit. Swift 6.2 on Xcode 26 can otherwise dead-strip these extracted
    # internal declarations and leave undefined symbols at link time.
    subprocess.run([swiftc, '-swift-version', '5', '-parse-as-library',
                    str(production), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
    # Compile the real decoder without iOS-only App Group container lookup.
    source = (root / 'ios/NECore/PacketTunnelSharedStateStore.swift').read_text(encoding='utf-8')
    decoder = source[source.index('struct PacketTunnelVPNOptions: Decodable {'):]
    test = pathlib.Path(directory) / 'mtu.swift'
    test.write_text('import Foundation\n' + decoder + '''
for (json, expected) in [("{}", 1500), ("{\\"mtu\\":9000}", 1500), ("{\\"mtu\\":500}", 1280), ("{\\"mtu\\":1400}", 1400)] {
  let options = try JSONDecoder().decode(PacketTunnelVPNOptions.self, from: Data(json.utf8))
  precondition(options.mtu == expected, "native MTU migration/clamp failed")
}
print("IOS_NATIVE_MTU_BEHAVIOR_PASS")
''', encoding='utf-8')
    subprocess.run([swiftc, str(test), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
