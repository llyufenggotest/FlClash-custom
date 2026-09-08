"""Regression tests for source-contract enforcement; never mutate production files."""
import contextlib
import io
from pathlib import Path
import runpy
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
READ_TEXT = Path.read_text


class IOSContractEnforcementTests(unittest.TestCase):
    def run_contract(self, target=None, old=None, new=None):
        replacements = []

        def read(path, *args, **kwargs):
            resolved = path if path.is_absolute() else ROOT / path
            text = READ_TEXT(resolved, *args, **kwargs)
            if target and resolved == ROOT / target:
                self.assertTrue(old in text, f'mutation must match real source: {target}: {old!r}')
                replacements.append(target)
                return text.replace(old, new, 1)
            return text

        output = io.StringIO()
        status = 0
        with patch.object(Path, 'read_text', read), contextlib.redirect_stdout(output):
            try:
                runpy.run_path(str(ROOT / 'scripts/verify_ios_contracts.py'), run_name='__main__')
            except SystemExit as exc:
                status = exc.code
        if target:
            self.assertTrue(replacements, 'mutation target was never read')
        return status, output.getvalue()

    def test_current_tree_passes_all_contracts(self):
        status, output = self.run_contract()
        self.assertEqual(status, 0, output)
        self.assertIn('IOS_ROOT_CAUSE_CONTRACT_PASS', output)

    def test_unsafe_regressions_are_rejected(self):
        mutations = [
            ('core/common.go', 'applyDNSListenerOwnership(nextConfig)', 'applyDNSListenerOwnership(currentConfig)'),
            ('core/hub.go', 'cacheName := secondaryCacheFileName', 'cacheName := ""'),
            ('core/hub.go', 'runnerCacheFileName(params.HomeDir, processHome)', 'runnerCacheFileName(params.HomeDir, sharedHome)'),
            ('core/hub.go', 'private path validation failed', 'private path validation removed'),
            ('core/runner_cache_path.go', 'filepath.IsAbs(processHome)', 'filepath.IsAbs("")'),
            ('core/runner_cache_path.go', 'os.Lstat(cachePath)', 'os.Lstat("")'),
            ('core/mihomo/constant/path.go', 'func SetCacheFileName', 'func RemovedSetCacheFileName'),
            ('ios/NECore/NativeDiagnosticLog.swift', 'static func retainedTail', 'static func removedTail'),
            ('ios/Runner/ServiceChannel.swift', 'if call.method != "invokeMethod"', 'if call.method == "never"'),
            ('ios/NECore/PacketTunnelProvider.swift', 'startup_failure phase=vpn_options_missing', 'startup_failure phase=removed'),
            ('ios/NECore/NativeResourceHeartbeat.swift', 'memory_pressure_warning', 'memory_pressure_removed'),
            ('ios/Runner/Tunnel/TunnelCoordinator.swift', 'connectTimeout: TimeInterval = 30', 'connectTimeout: TimeInterval = 0'),
            ('ios/Runner/Tunnel/TunnelManagerStore.swift', 'loadTimeout: TimeInterval = 15', 'loadTimeout: TimeInterval = 0'),
            ('ios/Runner/Tunnel/TunnelController.swift', 'providerMessageTimeout', 'providerMessageRemoved'),
            ('lib/plugins/service.dart', "invokeMethod<String>('getNativeLogs')", "invokeMethod<String>('removed')"),
            ('ios/NECore/PacketTunnelSharedStateStore.swift', 'func adoptStartOptions', 'func removedAdoptStartOptions'),
            ('core/memory_budget_ios_extension.go', 'delayBatchConcurrency = 8', 'delayBatchConcurrency = 1'),
        ]
        for target, old, new in mutations:
            with self.subTest(target=target, mutation=old):
                status, output = self.run_contract(target, old, new)
                self.assertEqual(status, 1, output)
                self.assertIn('FAIL ', output)
                self.assertNotIn('IOS_ROOT_CAUSE_CONTRACT_PASS', output)


if __name__ == '__main__':
    unittest.main()
