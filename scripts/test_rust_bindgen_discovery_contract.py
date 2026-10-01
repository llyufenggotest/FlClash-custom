import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HOOK = ROOT / "plugins" / "rust_api" / "hook" / "build.dart"


class RustBindgenDiscoveryContracts(unittest.TestCase):
    def test_linux_discovery_accepts_apt_libclang_symlinks(self):
        source = HOOK.read_text(encoding="utf-8")
        self.assertIn("final result = Process.runSync('find', [", source)
        self.assertIn("'libclang.so*'", source)
        self.assertIn("'-quit'", source)
        self.assertIn("[File(path).parent]", source)
        self.assertNotIn("'-type'", source)


if __name__ == "__main__":
    unittest.main()
