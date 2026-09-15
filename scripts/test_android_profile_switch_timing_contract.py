import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SETUP = ROOT / "lib" / "providers" / "actions" / "setup.dart"
CONTROLLER = ROOT / "lib" / "core" / "controller.dart"


class AndroidProfileSwitchTimingContractTest(unittest.TestCase):
    def test_switch_records_the_synchronous_critical_path(self):
        source = SETUP.read_text(encoding="utf-8")
        for phase in (
            "barrier_acquire",
            "delay_cancel",
            "profile_file",
            "render_config",
            "persist_config",
            "groups_sync",
            "providers_sync",
            "barrier_resume",
        ):
            self.assertIn("timing?.mark('%s')" % phase, source)

    def test_core_records_local_generation_and_apply_phases(self):
        source = CONTROLLER.read_text(encoding="utf-8")
        lookup = source.index("getPreparedRuleGeneration(")
        activate = source.index("_interface.activateRuleGeneration(", lookup)
        setup = source.index("_interface.setupConfig(params)", activate)
        self.assertLess(lookup, activate)
        self.assertLess(activate, setup)
        self.assertIn("timing?.mark('generation_lookup')", source[lookup:activate])
        self.assertIn("timing?.mark('generation_activate')", source[activate:setup])
        self.assertIn("timing?.mark('core_setup')", source[setup:])

    def test_android_switch_does_not_stop_the_tunnel(self):
        source = SETUP.read_text(encoding="utf-8")
        android_persist = source.index("if (!system.isIOS)")
        ios_activation = source.index("Future<void> commitAndActivate()", android_persist)
        self.assertNotIn(
            "setCoreRunning(false)", source[android_persist:ios_activation]
        )
        self.assertIn("allowRuleGenerationPreparation: allowRuleGenerationPreparation", source)


if __name__ == "__main__":
    unittest.main()
