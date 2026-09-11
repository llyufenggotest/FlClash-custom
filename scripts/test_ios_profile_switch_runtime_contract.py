import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class IOSProfileSwitchRuntimeContract(unittest.TestCase):
    def test_prepared_path_is_coalesced_with_generation(self) -> None:
        controller = (ROOT / "lib/core/controller.dart").read_text(encoding="utf-8")
        scheduler = (ROOT / "lib/core/rule_preparation_scheduler.dart").read_text(
            encoding="utf-8"
        )
        self.assertIn("PreparedGenerationScheduler<RuleGenerationPreparation>", scheduler)
        self.assertIn("preparedGenerationScheduler.prepare", controller)
        self.assertIn("candidateConfigPath = prepared.configPath", controller)
        self.assertNotIn("candidate config path is missing", controller)

    def test_profile_switch_selectively_cancels_delay_rpc(self) -> None:
        manager = (ROOT / "lib/manager/core_manager.dart").read_text(encoding="utf-8")
        service = (ROOT / "ios/Runner/ServiceChannel.swift").read_text(encoding="utf-8")
        self.assertIn("cancelDelayTests(cancelCoreRequests: true)", manager)
        self.assertIn('case "cancelDelayTests"', service)
        self.assertIn('entry.method == "asyncTestDelay"', service)
        self.assertIn(
            'rpcResponses.removeValue(forKey: token)?.finish(', service
        )
        cancel_block = service.split('case "cancelDelayTests":', 1)[1].split(
            'case "start":', 1
        )[0]
        self.assertNotIn("cancelNetworkExtensionRequests", cancel_block)
        self.assertNotIn("tunnelController.stop", cancel_block)

    def test_late_refreshes_are_profile_owned(self) -> None:
        proxies = (ROOT / "lib/providers/actions/proxies.dart").read_text(encoding="utf-8")
        providers = (ROOT / "lib/providers/app.dart").read_text(encoding="utf-8")
        setup = (ROOT / "lib/providers/actions/setup.dart").read_text(encoding="utf-8")
        self.assertIn("dropping stale profile result", proxies)
        self.assertIn("syncProviders({int? profileId})", providers)
        self.assertIn("profileId: expectedProfileId", setup)

    def test_fixture_matches_reported_overlap_shape(self) -> None:
        fixture = json.loads(
            (ROOT / "test/fixtures/ios_profile_switch_rpc_overlap.json").read_text(
                encoding="utf-8"
            )
        )
        self.assertGreaterEqual(fixture["delay_rpc_peak"], 8)
        self.assertIn("setupConfig", fixture["switch_overlap_methods"])
        self.assertIn("asyncTestDelay", fixture["switch_overlap_methods"])


if __name__ == "__main__":
    unittest.main()
