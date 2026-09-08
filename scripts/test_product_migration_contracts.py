import pathlib
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

    def test_brand_and_update_source_are_pinned(self):
        constants = self.read("lib/common/constant.dart")
        request = self.read("lib/common/request.dart")
        about = self.read("lib/views/about.dart")
        self.assertIn("chenx-dust/FlClash-Patched", constants)
        self.assertIn("api.github.com/repos/$repository/releases/latest", request)
        self.assertIn("dialogs.openUrl('https://github.com/$repository')", about)
        self.assertIn("chenx-dust/mihomo/tree/FlClash", about)


if __name__ == "__main__":
    unittest.main()
