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

    def test_profile_import_keeps_prepare_and_commit_in_one_loading_boundary(self):
        source = self.read("lib/providers/actions/profiles.dart")
        self.assertIn("Future<void> _addPreparedProfile", source)
        self.assertIn("await putPreparedProfile(", source)
        self.assertIn(
            "ProfileCommitPreparationPolicy.validateAndCommitOnly",
            source,
        )
        helper_start = source.index("Future<void> _addPreparedProfile")
        helper_end = source.index("Future<void> addOppaProfile", helper_start)
        helper = source[helper_start:helper_end]
        self.assertIn("globalState.loadingRun<void>", helper)
        self.assertLess(
            helper.index("globalState.loadingRun<void>"),
            helper.index("await putPreparedProfile"),
        )
        self.assertIn("showCoreUnavailableErrors: true", helper)
        state = self.read("lib/state.dart")
        self.assertIn("bool showCoreUnavailableErrors = false", state)
        self.assertIn(
            "if (!showCoreUnavailableErrors && isCoreUnavailableError(e))",
            state,
        )
        self.assertIn("final prepared = await futureFunction();", helper)

    def test_file_url_and_qr_share_prepare_pipeline(self):
        source = self.read("lib/providers/actions/profiles.dart")
        self.assertIn("prepareFile(bytes, prepare: prepareProfileConfig)", source)
        self.assertIn(".prepareUpdate(prepare: prepareProfileConfig)", source)
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

    def test_desktop_yaml_drop_reuses_profile_validation_pipeline(self):
        pubspec = self.read("pubspec.yaml")
        app = self.read("lib/application.dart")
        actions = self.read("lib/providers/actions/profiles.dart")
        self.assertIn("desktop_drop:", pubspec)
        self.assertIn("DropTarget(", app)
        self.assertIn("!system.isWindows && !system.isMacOS", app)
        self.assertIn(".yaml", app)
        self.assertIn(".yml", app)
        self.assertIn("addProfileFromDroppedFile", app)
        self.assertIn("startAccessingSecurityScopedResource", app)
        self.assertIn("stopAccessingSecurityScopedResource", app)
        self.assertIn("DropItemDirectory", app)
        self.assertIn("32 * 1024 * 1024", app)
        self.assertIn("file.openRead()", app)
        self.assertIn("builder.length + chunk.length", app)
        self.assertNotIn("await file.length()", app)
        self.assertNotIn("await file.readAsBytes()", app)
        self.assertIn("Future<void> addProfileFromDroppedFile", actions)
        self.assertIn("prepareFile(bytes, prepare: prepareProfileConfig)", actions)

    def test_subscription_addition_waits_for_resource_readiness_before_database_commit(self):
        actions = self.read("lib/providers/actions/profiles.dart")
        database = self.read("lib/providers/database.dart")
        setup = self.read("lib/providers/actions/setup.dart")

        self.assertIn("bool Function()? postCommitGuard", actions)
        self.assertIn("if (postCommitGuard != null && !postCommitGuard())", actions)
        commit_start = actions.index("Future<void> _commitPreparedProfile")
        commit_end = actions.index("Future<void> putPreparedProfile", commit_start)
        commit = actions[commit_start:commit_end]
        db_put = commit.index("await ref.read(profilesProvider.notifier).putAsync(profile)")
        after_db_put = commit[db_put:]
        self.assertNotIn(
            "if (commitGuard != null && !commitGuard())",
            after_db_put,
        )
        update_start = actions.index("Future<void> updateProfile")
        update_end = actions.index("Future<void> _addPreparedProfile", update_start)
        self.assertIn("postCommitGuard:", actions[update_start:update_end])
        self.assertIn("Future<void> putPreparedProfile", actions)
        self.assertIn("await putPreparedProfile(", actions)
        self.assertIn(
            "ProfileCommitPreparationPolicy.validateAndCommitOnly",
            actions,
        )
        self.assertIn("candidateYaml: candidateYaml", actions)
        self.assertIn("await _core.activateRuleGeneration", actions)
        self.assertIn("await ref.read(profilesProvider.notifier).putAsync(profile)", actions)
        self.assertIn("Future<void> putAsync(Profile profile)", database)
        self.assertIn("allowUncommittedProfile = false", setup)
        put_profile = actions.split("void putProfile(Profile profile)", 1)[1].split(
            "Future<void> updateProfiles", 1
        )[0]
        self.assertNotIn("_scheduleRulePrewarm", put_profile)

    def test_ci_preserves_matrix_and_adds_protocol_gates(self):
        workflow = self.read(".github/workflows/build.yaml")
        for platform in ("android", "ios", "linux", "windows", "macos"):
            self.assertIn(f"platform: {platform}", workflow)
        self.assertIn("protocol-contract:", workflow)
        self.assertIn("submodules: recursive", workflow)
        self.assertIn("98c4afa30d95f4af5bdaa18abf8ff6cc6d3ed8d7", workflow)
        self.assertIn("7eb702723de9cd7b51d25b3e207f3feafb0f07a4", workflow)
        self.assertIn("with_low_memory", workflow)
        self.assertIn("MAGIC_SHANLIAN_TRIGGER", workflow)
        self.assertIn("protocol_smoke", workflow)

    def test_five_platform_workflow_uses_release_toolchains(self):
        release_workflow = self.read(".github/workflows/build.yaml")
        matrix_workflow = self.read(".github/workflows/ios-five-protocol.yaml")
        gradle_versions = self.read("android/gradle/libs.versions.toml")
        flutter = re.search(
            r"^  FLUTTER_VERSION: '([^']+)'$", release_workflow, re.MULTILINE
        )
        self.assertIsNotNone(flutter)
        flutter_marker = f"FLUTTER_VERSION: '{flutter.group(1)}'"
        self.assertIn(flutter_marker, matrix_workflow)
        self.assertIn("GO_VERSION: '1.26.8'", release_workflow)
        ndk = re.search(r'^ndkVersion = "([^"]+)"$', gradle_versions, re.MULTILINE)
        self.assertIsNotNone(ndk)
        ndk_marker = f"NDK_VERSION: '{ndk.group(1)}'"
        self.assertIn("NDK_VERSION: r29", release_workflow)
        self.assertIn(ndk_marker, matrix_workflow)
        self.assertIn("github.event_name == 'push'", matrix_workflow)
        self.assertEqual(matrix_workflow.count("github.event_name == 'push'"), 3)
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
        rust_hook = self.read("plugins/rust_api/hook/build.dart")

        self.assertIn("class RuleProviderFileDownload", request)
        self.assertIn("downloadRuleProviderToFile", request)
        for method in (
            "prewarmRuleProvider",
            "publishRuleGeneration",
            "getPreparedRuleGeneration",
            "validateCandidateConfigAtPath",
        ):
            self.assertIn(method, methods)
        self.assertIn("Future<RuleGenerationPreparation?> prewarmProfile(", setup)
        self.assertIn("import 'dart:convert';", profiles)
        self.assertIn("import 'dart:typed_data';", profiles)
        self.assertIn("dialogs.showMessage", logs)
        self.assertIn("_listController.setLogs(const [])", logs)
        self.assertIn("package:fl_clash/widgets/widgets.dart", oppa)
        self.assertIn("CommonDialog(", oppa)
        self.assertIn("Process.runSync('llvm-config', ['--libdir'])", rust_hook)
        self.assertIn("on ProcessException", rust_hook)
        self.assertIn("llvmConfig = null", rust_hook)
        self.assertIn("'/usr/lib/llvm-18/lib'", rust_hook)
        self.assertIn("_containsLibclang", rust_hook)


if __name__ == "__main__":
    unittest.main()
