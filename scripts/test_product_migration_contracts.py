import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class ProductMigrationContractTest(unittest.TestCase):
    def read(self, path):
        return (ROOT / path).read_text(encoding="utf-8")

    def test_fastup_is_normalized_before_decrypt_and_validation(self):
        source = self.read("lib/providers/actions/profiles.dart")
        normalize = source.index("convertFastupSubscription")
        decrypt = source.index("decryptAgeConfig")
        validate = source.index("validateConfig(prepared)")
        self.assertLess(normalize, decrypt)
        self.assertLess(decrypt, validate)

    def test_file_url_and_qr_share_prepare_pipeline(self):
        source = self.read("lib/providers/actions/profiles.dart")
        self.assertIn("saveFile(bytes, prepare: prepareProfileConfig)", source)
        self.assertIn(".update(prepare: prepareProfileConfig)", source)
        self.assertIn("addProfileFormURL(url)", source)

    def test_oppa_product_flow_and_explicit_read_only_policy(self):
        actions = self.read("lib/providers/actions/profiles.dart")
        add_view = self.read("lib/views/profiles/add.dart")
        edit_view = self.read("lib/views/profiles/edit.dart")
        policy = self.read("lib/common/protocol_edit_policy.dart")
        self.assertIn("addOppaProfile", actions)
        self.assertIn("OppaProfileDialog", add_view)
        self.assertIn("ProtocolEditPolicy", edit_view)
        self.assertIn("xhttp", policy.lower())
        self.assertIn("blackstone", policy.lower())
        self.assertIn("oppa", policy.lower())

    def test_ci_preserves_matrix_and_adds_protocol_gates(self):
        workflow = self.read(".github/workflows/build.yaml")
        for platform in ("android", "ios", "linux", "windows", "macos"):
            self.assertIn(f"platform: {platform}", workflow)
        self.assertIn("protocol-contract:", workflow)
        self.assertIn("submodules: recursive", workflow)
        self.assertIn("98c4afa30d95f4af5bdaa18abf8ff6cc6d3ed8d7", workflow)
        self.assertIn("294e072d12f5a068f86f5b275fc9c49544c3f4fa", workflow)
        self.assertIn("with_low_memory", workflow)
        self.assertIn("MAGIC_SHANLIAN_TRIGGER", workflow)
        self.assertIn("protocol_smoke", workflow)

    def test_five_platform_workflow_uses_release_toolchains(self):
        release_workflow = self.read(".github/workflows/build.yaml")
        matrix_workflow = self.read(".github/workflows/ios-five-protocol.yaml")
        gradle_versions = self.read("android/gradle/libs.versions.toml")
        flutter_marker = "FLUTTER_VERSION: '3.47.2'"
        self.assertIn(flutter_marker, release_workflow)
        self.assertIn(flutter_marker, matrix_workflow)
        ndk = re.search(r'^ndkVersion = "([^"]+)"$', gradle_versions, re.MULTILINE)
        self.assertIsNotNone(ndk)
        ndk_marker = f"NDK_VERSION: '{ndk.group(1)}'"
        self.assertIn(ndk_marker, release_workflow)
        self.assertIn(ndk_marker, matrix_workflow)
        self.assertIn("NDK_RELEASE: r28c", matrix_workflow)
        self.assertIn("ndk-version: ${{ env.NDK_RELEASE }}", matrix_workflow)
        self.assertIn(
            "flutter test test/common/oppa_yaml_test.dart", matrix_workflow
        )

    def test_brand_and_update_source_are_pinned(self):
        constants = self.read("lib/common/constant.dart")
        request = self.read("lib/common/request.dart")
        about = self.read("lib/views/about.dart")
        self.assertIn("chenx-dust/FlClash-Patched", constants)
        self.assertIn("api.github.com/repos/$repository/releases/latest", request)
        self.assertIn("dialogs.openUrl('https://github.com/$repository')", about)
        self.assertIn("chenx-dust/mihomo/tree/FlClash", about)

    def test_dart_migration_keeps_rule_prewarm_and_current_ui_contracts(self):
        request = self.read("lib/common/request.dart")
        methods = self.read("lib/core/method.dart")
        setup = self.read("lib/providers/actions/setup.dart")
        profiles = self.read("lib/providers/action.dart")
        logs = self.read("lib/views/logs.dart")
        oppa = self.read("lib/views/profiles/oppa_profile_dialog.dart")

        self.assertIn("class RuleProviderFileDownload", request)
        self.assertIn("downloadRuleProviderToFile", request)
        for method in (
            "prewarmRuleProvider",
            "publishRuleGeneration",
            "getPreparedRuleGeneration",
            "validateCandidateConfigAtPath",
        ):
            self.assertIn(method, methods)
        self.assertIn("Future<bool> prewarmProfile(Profile profile)", setup)
        self.assertIn("import 'dart:convert';", profiles)
        self.assertIn("import 'dart:typed_data';", profiles)
        self.assertIn("dialogs.showMessage", logs)
        self.assertIn("_listController.setLogs(const [])", logs)
        self.assertIn("package:fl_clash/widgets/widgets.dart", oppa)
        self.assertIn("CommonDialog(", oppa)


if __name__ == "__main__":
    unittest.main()
