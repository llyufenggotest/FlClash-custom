# This file documents and gates the experimental sideload compatibility dylib.
# It intentionally fails on the verified baseline before any production integration.
import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DYLIB_NAME = "Tg_@HelloWorld_1024.dylib"
EXPECTED_SHA256 = "cd903ea15657cbd356398adcb60c8872c41c29b69acc1a5dfb78a49d6e75dea5"


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


asset = ROOT / "ios" / "SideloadSupport" / DYLIB_NAME
project = (ROOT / "ios" / "Runner.xcodeproj" / "project.pbxproj").read_text(encoding="utf-8")
workflow = (ROOT / ".github" / "workflows" / "ios-five-protocol.yaml").read_text(encoding="utf-8")
app_delegate = (ROOT / "ios" / "Runner" / "AppDelegate.swift").read_text(encoding="utf-8")

check(asset.is_file(), "trusted dylib is not vendored in ios/SideloadSupport")
check(hashlib.sha256(asset.read_bytes()).hexdigest() == EXPECTED_SHA256,
      "trusted dylib hash changed")
check("SideloadSupport/Tg_@HelloWorld_1024.dylib" in project,
      "Runner Xcode project does not reference the dylib")
check('name = "Tg_@HelloWorld_1024.dylib"' in project and
      'path = "SideloadSupport/Tg_@HelloWorld_1024.dylib"' in project,
      "Xcode project must quote dylib name/path because @ is PBX syntax")
check("Tg_@HelloWorld_1024.dylib in Embed Frameworks" in project,
      "Runner target does not embed the dylib into Frameworks")
check("Tg_@HelloWorld_1024.dylib in Frameworks" not in project,
      "do not link the embedded output back into Runner; Xcode reports a target cycle")
check("-weak_library" not in project,
      "runtime dlopen is the only load edge; weak-linking the copied output creates a cycle")
check("dlopen" in app_delegate and "Tg_@HelloWorld_1024.dylib" in app_delegate,
      "Runner does not explicitly load the embedded dylib from Frameworks")
check("RTLD_NOW | RTLD_LOCAL" in app_delegate,
      "Runner does not use deterministic local dlopen flags")
check("Verify sideload compatibility dylib" in workflow,
      "CI does not inspect the final IPA for the dylib")
check("EXPECTED_SIDELOAD_DYLIB_SHA256" in workflow,
      "CI does not pin the trusted dylib hash")
check("Payload/Runner.app/Frameworks/Tg_@HelloWorld_1024.dylib" in workflow,
      "CI does not require the dylib at the exact claimed IPA path")
print("IOS_SIDELOAD_DYLIB_CONTRACT_PASS")
