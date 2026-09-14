"""Source contracts for committed generation setup and progress UI."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]

class SetupGenerationContracts(unittest.TestCase):
    def test_switch_is_find_only_and_desktop_still_applies_core(self):
        source = (ROOT / "lib/core/controller.dart").read_text(encoding="utf-8")
        self.assertIn("allowRuleGenerationPreparation", source)
        self.assertIn("getPreparedRuleGeneration", source)
        self.assertIn("return _interface.setupConfig(params);", source)
        setup = (ROOT / "lib/providers/actions/setup.dart").read_text(encoding="utf-8")
        self.assertIn("allowRuleGenerationPreparation = true", setup)
        profiles = (ROOT / "lib/providers/actions/profiles.dart").read_text(encoding="utf-8")
        self.assertNotIn("ProfileCommitPreparationPolicy", profiles)
        self.assertIn(".saveFile(bytes, prepare: prepareProfileConfig)", profiles)
        self.assertIn(".update(prepare: prepareProfileConfig)", profiles)
        self.assertIn("allowRuleGenerationPreparation: true", setup)
        self.assertIn("profileSwitched: profileSwitched", setup)
        self.assertIn("allowRuleGenerationPreparation: allowRuleGenerationPreparation", setup)

    def test_progress_is_riverpod_backed_and_visible(self):
        action = (ROOT / "lib/providers/action.dart").read_text(encoding="utf-8")
        setup = (ROOT / "lib/providers/actions/setup.dart").read_text(encoding="utf-8")
        profiles = (ROOT / "lib/views/profiles/profiles.dart").read_text(encoding="utf-8")
        self.assertIn("rulePreparationProgressProvider", action)
        self.assertIn("onProgress:", setup)
        self.assertIn("rulePreparationProgressProvider", profiles)
        self.assertIn("rulePreparationProgress", profiles)

if __name__ == "__main__":
    unittest.main()
