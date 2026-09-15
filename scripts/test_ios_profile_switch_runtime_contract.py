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
        self.assertIn("candidateConfigPath = activatedPath", controller)
        self.assertNotIn("candidate config path is missing", controller)

    def test_ios_generation_writers_never_route_to_ne(self):
        router = (ROOT / "ios/Runner/Core/CoreMessageRouter.swift").read_text(encoding="utf-8")
        methods = [
            "prewarmProxyProvider", "prewarmRuleProvider", "publishRuleGeneration",
            "activateRuleGeneration", "restoreRuleGeneration", "getPreparedRuleGeneration",
            "validateStagedConfigAtPath", "validateCandidateConfigAtPath", "deleteManagedPath",
        ]
        enum_block = router.split("private enum AppCoreMethod", 1)[1].split("}", 1)[0]
        for method in methods:
            self.assertIn(f"case {method}", enum_block)
        route_block = router.split("private func route(", 1)[1]
        self.assertIn("AppCoreMethod(rawValue: method) != nil", route_block)
        self.assertIn("return .app", route_block)

        manager = (ROOT / "lib/manager/core_manager.dart").read_text(encoding="utf-8")
        service = (ROOT / "ios/Runner/ServiceChannel.swift").read_text(encoding="utf-8")
        self.assertIn("cancelDelayTests(cancelCoreRequests: true)", manager)
        self.assertIn('case "cancelDelayTests"', service)
        self.assertIn('entry.method == "asyncTestDelay"', service)
        default_scheduler = (ROOT / "core/delay_scheduler_default.go").read_text(
            encoding="utf-8"
        )
        self.assertIn("manualProbeCtx", default_scheduler)
        self.assertIn("manualProbeStop()", default_scheduler)
        go_methods = (ROOT / "core/method.go").read_text(encoding="utf-8")
        self.assertIn("handleAsyncTestDelay(params", go_methods)
        self.assertNotIn("response.success(handleTestDelay(params))", go_methods)
        self.assertNotIn("func cancelDelayTests() {}", default_scheduler)
        self.assertIn(
            'rpcTasks.removeValue(forKey: token)?.cancel()', service
        )
        self.assertIn('coreMessageRouter.cancelDelayTests()', service)
        mailbox = (ROOT / "ios/NECore/ProviderMessageMailbox.swift").read_text(
            encoding="utf-8"
        )
        self.assertIn('method == "cancelDelayTests"', mailbox)
        self.assertIn('interruptOutstanding < 1', mailbox)
        self.assertIn('configurationOutstanding < 1', mailbox)
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
        self.assertIn("ActivationEpochOwnership", setup)
        self.assertIn("publishIfOwned(epoch", setup)

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
