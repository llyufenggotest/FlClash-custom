#!/usr/bin/env python
"""Run actual production Swift diagnostics/resource behavior on macOS CI.
Usage: python scripts/test_necore_diagnostics_behavior.py
Requires Swift + macOS Foundation/Darwin (no Xcode project or core library).
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import sys

ROOT = Path(__file__).resolve().parents[1]
if not shutil.which('swiftc'):
    print('BLOCKED: swiftc unavailable; behavior tests were NOT executed', file=sys.stderr)
    sys.exit(2)
with tempfile.TemporaryDirectory(prefix='necore-diagnostics-') as tmp:
    tmp = Path(tmp)
    # Actual production implementations, with only external integration stubs.
    stubs = '''import Foundation
    enum PacketTunnelEnvironment { static let appGroupIdentifier = "test.invalid" }
    enum NECoreBridge { static func releaseMemory() {} }
    '''
    (tmp / 'Stubs.swift').write_text(stubs, encoding='utf-8')
    shutil.copy(ROOT / 'tests/native/DiagnosticsBehavior.swift', tmp / 'main.swift')
    output = tmp / 'diagnostics-tests'
    subprocess.run(['swiftc', '-o', str(output), str(tmp / 'Stubs.swift'),
                    str(ROOT / 'ios/NECore/NativeDiagnosticLog.swift'),
                    str(ROOT / 'ios/NECore/NativeResourceHeartbeat.swift'),
                    str(tmp / 'main.swift')], check=True)
    subprocess.run([str(output)], check=True)
