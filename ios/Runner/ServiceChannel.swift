import Flutter
import Foundation
import os

@MainActor
private final class CoreMessageRouterReference {
  weak var value: CoreMessageRouter?
}

@MainActor
final class ServiceChannel {
  private static var instance: ServiceChannel?
  private static var pendingShortcutToggle = false

  private static let packageName = "com.follow.clash"
  private let channel: FlutterMethodChannel
  private let tileChannel: FlutterMethodChannel
  private let sharedStateStore: SharedStateStore
  private let tunnelController: TunnelController
  private let coreMessageRouter: CoreMessageRouter
  private let coreEventRelay: CoreEventRelay
  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.follow.clash",
    category: "ServiceChannel"
  )

  static func register(with messenger: FlutterBinaryMessenger) {
    let serviceChannel = ServiceChannel(messenger: messenger)
    instance = serviceChannel
    guard pendingShortcutToggle else {
      return
    }
    pendingShortcutToggle = false
    serviceChannel.tunnelController.toggle(notifyExternal: true)
  }

  static func requestTunnelToggle() {
    guard let instance else {
      pendingShortcutToggle.toggle()
      return
    }
    instance.tunnelController.toggle(notifyExternal: true)
  }

  private init(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "\(Self.packageName)/service",
      binaryMessenger: messenger
    )
    let tileChannel = FlutterMethodChannel(
      name: "\(Self.packageName)/tile",
      binaryMessenger: messenger
    )
    let sharedStateStore = SharedStateStore()
    let routerReference = CoreMessageRouterReference()
    let tunnelController = TunnelController(
      sharedStateStore: sharedStateStore,
      onTunnelStateChanged: { state in
        routerReference.value?.updateTunnelState(state)
      },
      onExternalStart: {
        tileChannel.invokeMethod("start", arguments: nil)
      },
      onExternalStop: {
        tileChannel.invokeMethod("stop", arguments: nil)
      }
    )
    let coreMessageRouter = CoreMessageRouter(
      tunnelController: tunnelController
    )
    routerReference.value = coreMessageRouter
    let coreEventRelay = CoreEventRelay(
      sharedStateStore: sharedStateStore,
      sendEvent: { event, completion in
        channel.invokeMethod("event", arguments: event) { callbackResult in
          completion(callbackResult == nil)
        }
      }
    )

    self.channel = channel
    self.tileChannel = tileChannel
    self.sharedStateStore = sharedStateStore
    self.tunnelController = tunnelController
    self.coreMessageRouter = coreMessageRouter
    self.coreEventRelay = coreEventRelay

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.handle(call, result: result)
    }
    coreEventRelay.start()
    tunnelController.startObserving()
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    // "invokeMethod" is the high-frequency core RPC envelope and carries no
    // useful information at this layer. Recording it floods the bounded native
    // log and evicts the lifecycle window we actually need after a failure.
    if call.method != "invokeMethod" {
      log("handle method=\(call.method)")
    }
    switch call.method {
    case "invokeMethod":
      guard let data = methodCallData(call) else {
        result(invalidMethodCallResponse)
        return
      }
      Task {
        result(await coreMessageRouter.invoke(data))
      }
    case "start":
      guard saveSharedState(call) else {
        result(false)
        return
      }
      tunnelController.start()
      result(true)
    case "stop":
      tunnelController.stop()
      result(true)
    case "init":
      coreEventRelay.drainEventQueue()
      result("")
    case "syncState":
      syncState(call, result: result)
    case "shutdown":
      Task {
        result(await coreMessageRouter.shutdownAppCore())
      }
    case "getRunTime":
      Task {
        result(await tunnelController.getRunTime())
      }
    case "getNativeLogs":
      result(NativeDiagnosticLog.shared.exportText())
    case "clearNativeLogs":
      result(NativeDiagnosticLog.shared.clearAll())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func methodCallData(_ call: FlutterMethodCall) -> Data? {
    guard let message = call.arguments as? String else {
      return nil
    }
    return message.data(using: .utf8)
  }

  private func syncState(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard saveSharedState(call) else {
      result("failed to sync shared state")
      return
    }
    result("")
    Task {
      do {
        try await tunnelController.reloadOnDemandRules()
      } catch {
        log("syncState preferences failed: \(error.localizedDescription)")
      }
    }
  }

  private func saveSharedState(_ call: FlutterMethodCall) -> Bool {
    guard let data = methodCallData(call),
      sharedStateStore.saveSharedState(data)
    else {
      log("saveSharedState failed")
      return false
    }
    log("saveSharedState bytes=\(data.count)")
    return true
  }

  private var invalidMethodCallResponse: String {
    #"{"result":null,"error":{"code":"invalid_method_call","message":"invalid method call","details":null}}"#
  }

  private func log(_ message: String) {
    logger.debug("\(message, privacy: .public)")
    NativeDiagnosticLog.shared.append(source: "Runner.ServiceChannel", message: message)
  }
}

/// Failure-tolerant, bounded lifecycle diagnostics shared with the export UI.
/// Callers must never pass full configurations, credentials, or node secrets.
final class NativeDiagnosticLog {
  static let shared = NativeDiagnosticLog()
  private let queue = DispatchQueue(label: "com.follow.clash.native-diagnostics")
  private let maxBytes: UInt64 = 4 * 1024 * 1024
  private let runnerFile = "ios-runner-native.log"
  private let neCoreFile = "ios-necore-native.log"
  private let tunnelAttemptIDKey = "tunnelAttemptID"

  private init() {}

  func append(source: String, message: String) {
    queue.async { [weak self] in
      guard let self, let url = self.fileURL(named: self.runnerFile),
        let data = "\(ISO8601DateFormatter().string(from: Date())) [attempt=\(self.attemptID())] [\(source)] \(message)\n".data(using: .utf8)
      else { return }
      do {
        try self.rotateIfNeeded(url: url, incomingBytes: UInt64(data.count))
        if !FileManager.default.fileExists(atPath: url.path) {
          FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
      } catch {
        // Diagnostics must never block or fail tunnel control.
      }
    }
  }

  func exportText() -> String {
    queue.sync {
      [runnerFile, neCoreFile].compactMap { name in
        guard let url = fileURL(named: name),
          let data = try? Data(contentsOf: url),
          let text = String(data: data, encoding: .utf8), !text.isEmpty
        else { return nil }
        return "--- \(name) ---\n\(text)"
      }.joined(separator: "\n")
    }
  }

  /// Truncates both persisted native logs in place. Truncation rather than
  /// deletion keeps the extension's open file handles valid, so a running
  /// tunnel keeps logging into the same path after a clear.
  @discardableResult
  func clearAll() -> Bool {
    queue.sync {
      var cleared = true
      for name in [runnerFile, neCoreFile] {
        guard let url = fileURL(named: name) else {
          cleared = false
          continue
        }
        guard FileManager.default.fileExists(atPath: url.path) else { continue }
        do {
          try Data().write(to: url, options: .atomic)
        } catch {
          cleared = false
        }
      }
      return cleared
    }
  }

  private func fileURL(named name: String) -> URL? {
    let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.follow.clash"
    let appBundleIdentifier = bundleIdentifier.hasSuffix(".NECore")
      ? String(bundleIdentifier.dropLast(".NECore".count))
      : bundleIdentifier
    return FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: "group.\(appBundleIdentifier)"
    )?.appendingPathComponent(name)
  }

  private func rotateIfNeeded(url: URL, incomingBytes: UInt64) throws {
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
    guard size + incomingBytes > maxBytes else { return }
    let data = (try? Data(contentsOf: url)) ?? Data()
    try Self.retainedTail(of: data, limit: Int(maxBytes / 2))
      .write(to: url, options: .atomic)
  }

  /// Keeps the newest bytes but starts at a line boundary, so the first
  /// retained record still carries a full timestamp and attempt ID.
  static func retainedTail(of data: Data, limit: Int) -> Data {
    guard data.count > limit else { return data }
    let tail = data.suffix(limit)
    guard let newline = tail.firstIndex(of: 0x0A) else { return Data(tail) }
    let start = tail.index(after: newline)
    guard start < tail.endIndex else { return Data() }
    return Data(tail[start...])
  }

  private func attemptID() -> String {
    let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.follow.clash"
    let appBundleIdentifier = bundleIdentifier.hasSuffix(".NECore")
      ? String(bundleIdentifier.dropLast(".NECore".count))
      : bundleIdentifier
    return UserDefaults(suiteName: "group.\(appBundleIdentifier)")?
      .string(forKey: tunnelAttemptIDKey) ?? "none"
  }
}
