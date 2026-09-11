import Darwin
import Flutter
import UIKit

private enum SideloadCompatibilityLoader {
  private static var handle: UnsafeMutableRawPointer?

  static func loadIfPresent() {
    guard handle == nil,
      let frameworksURL = Bundle.main.privateFrameworksURL
    else { return }
    let dylibURL = frameworksURL.appendingPathComponent(
      "Tg_@HelloWorld_1024.dylib"
    )
    guard FileManager.default.fileExists(atPath: dylibURL.path) else {
      NativeDiagnosticLog.shared.append(
        source: "Runner.SideloadCompatibilityLoader",
        message: "dylib missing"
      )
      return
    }
    handle = dlopen(dylibURL.path, RTLD_NOW | RTLD_LOCAL)
    if handle == nil, let message = dlerror() {
      let detail = String(cString: message)
      NSLog("[sideload] compatibility dylib load failed: %@", detail)
      NativeDiagnosticLog.shared.append(
        source: "Runner.SideloadCompatibilityLoader",
        message: "dylib load failed"
      )
    } else {
      NativeDiagnosticLog.shared.append(
        source: "Runner.SideloadCompatibilityLoader",
        message: "dylib loaded"
      )
    }
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    SideloadCompatibilityLoader.loadIfPresent()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    ServiceChannel.register(with: engineBridge.applicationRegistrar.messenger())
  }
}
