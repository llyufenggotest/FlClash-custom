import Darwin
import Foundation
import NetworkExtension
import WidgetKit
import os

private enum NECoreSideloadCompatibilityLoader {
  private static var handle: UnsafeMutableRawPointer?

  static func loadIfPresent() {
    guard handle == nil,
      let frameworksURL = Bundle.main.privateFrameworksURL
    else { return }
    let dylibURL = frameworksURL.appendingPathComponent(
      "Tg_@HelloWorld_1024.dylib"
    )
    guard FileManager.default.fileExists(atPath: dylibURL.path) else {
      NativeDiagnosticLog.shared.append("sideload dylib missing")
      return
    }
    handle = dlopen(dylibURL.path, RTLD_NOW | RTLD_LOCAL)
    NativeDiagnosticLog.shared.append(
      handle == nil ? "sideload dylib load failed" : "sideload dylib loaded"
    )
  }
}

final class PacketTunnelProvider: NEPacketTunnelProvider {
  private let sharedStateStore = PacketTunnelSharedStateStore()
  private let networkConfiguration = PacketTunnelNetworkConfiguration()
  private lazy var eventQueue = NECoreEventQueue(
    sharedStateStore: sharedStateStore
  )
  private lazy var mailbox = ProviderMessageMailbox(
    directory: sharedStateStore.providerMessageMailboxDirectory(),
    invoke: { data, reply in NECoreBridge.invokeMethod(data) { reply($0) } },
    markResponsive: { [weak self] in self?.eventQueue.markCoreResponsive() }
  )
  private let lifecycleQueue = DispatchQueue(label: "com.follow.clash.ne.lifecycle")
  private var generation: UInt64 = 0
  private var pendingStart: ((Error?) -> Void)?
  private let setupBarrierLock = NSLock()
  private var setupBarrier: CoreSetupStopBarrier {
    setupBarrierLock.lock()
    defer { setupBarrierLock.unlock() }
    return setupBarrierStorage
  }
  private lazy var setupBarrierStorage: CoreSetupStopBarrier = {
    let queue = lifecycleQueue
    return CoreSetupStopBarrier(
      cleanup: { completion in
        queue.async {
          // This barrier is the sole owner of core retirement. Do not stop TUN
          // before an outstanding quickSetup returns: late setup may recreate it.
          let request = Data(#"{"method":"shutdown","arguments":null}"#.utf8)
          let cleanupGate = CoreShutdownCleanupGate(completion: completion)
          NECoreBridge.invokeMethod(request) { data in
            let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            let success = object?["result"] as? Bool == true
              && (object?["error"] == nil || object?["error"] is NSNull)
            cleanupGate.receiveShutdownResult(success)
          }
          // invokeMethod may call back inline. Record local retirement only after
          // stopTun returns so barrier completion can never overtake it.
          NECoreBridge.stopTun()
          cleanupGate.didStopTun()
        }
      },
      cleanupTimeout: CoreSetupStopBarrier.providerStopDeadline,
      scheduleTimeout: CoreSetupStopBarrier.scheduleStopDeadline,
      diagnostic: { [weak self] reason in
        self?.logger.error("stopTunnel \(reason, privacy: .public)")
        self?.nativeLog("stopTunnel \(reason)")
      }
    )
  }()
  private let logger = Logger(
    subsystem: PacketTunnelEnvironment.extensionBundleIdentifier,
    category: "PacketTunnelProvider"
  )

  private var suspendSupport = true
  private var didStartEventQueue = false
  private var didStartTun = false
  private let resourceHeartbeat = NativeResourceHeartbeat()

  override func startTunnel(
    options: [String: NSObject]?,
    completionHandler: @escaping (Error?) -> Void
  ) {
    lifecycleQueue.async {
      self.beginStart(options: options, completionHandler: completionHandler)
    }
  }

  private func beginStart(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
    // Do not overlap two Go quickSetup operations in one provider instance.
    guard pendingStart == nil, !didStartTun, setupBarrier.canStart else {
      completionHandler(PacketTunnelProviderError.startCancelled)
      return
    }
    generation &+= 1
    let attempt = generation
    pendingStart?(PacketTunnelProviderError.startCancelled)
    pendingStart = completionHandler
    let completionHandler: (Error?) -> Void = { error in
      guard self.generation == attempt, let pending = self.pendingStart else { return }
      self.pendingStart = nil
      pending(error)
    }
    NECoreSideloadCompatibilityLoader.loadIfPresent()
    logger.info("startTunnel begin")
    nativeLog("startTunnel begin")
    sharedStateStore.clearRunTime()
    reloadControlWidget()
    // Prefer the payload the system delivered in memory; fall back to the App
    // Group suite, then to the snapshot the app committed before starting.
    sharedStateStore.adoptStartOptions(options)
    nativeLog("startTunnel options keys=\(options?.keys.sorted().joined(separator: ",") ?? "none")")
    let stateResult = sharedStateStore.loadVPNOptionsResult()
    guard let vpnOptions = stateResult.options else {
      let failure = stateResult.failure?.rawValue ?? "unknown"
      logger.error("startTunnel failed: missing vpn options reason=\(failure, privacy: .public)")
      nativeLog("startTunnel failed missing_vpn_options reason=\(failure)")
      nativeLog("startup_failure phase=vpn_options_missing reason=\(failure)")
      completionHandler(PacketTunnelProviderError.missingVPNOptions)
      return
    }
    nativeLog(
      "shared_state source=\(stateResult.source?.rawValue ?? "unknown") bytes=\(stateResult.byteCount)"
    )
    logger.info(
      "startTunnel options stack=\(vpnOptions.stack, privacy: .public) ipv6=\(vpnOptions.ipv6, privacy: .public) captureDns=\(vpnOptions.captureDns, privacy: .public) systemProxy=\(vpnOptions.systemProxy, privacy: .public) suspendSupport=\(vpnOptions.suspendSupport, privacy: .public)"
    )
    nativeLog("vpnOptions loaded stack=\(vpnOptions.stack) ipv6=\(vpnOptions.ipv6) captureDns=\(vpnOptions.captureDns) systemProxy=\(vpnOptions.systemProxy) suspendSupport=\(vpnOptions.suspendSupport)")
    suspendSupport = vpnOptions.suspendSupport

    setTunnelNetworkSettings(
      networkConfiguration.makeSettings(for: vpnOptions)
    ) { error in
      self.lifecycleQueue.async {
      guard self.generation == attempt, self.pendingStart != nil else { return }
      if let error {
        self.logger.error(
          "setTunnelNetworkSettings failed: \(error.localizedDescription, privacy: .public)"
        )
        self.nativeLog("setTunnelNetworkSettings failed error=\(self.safeError(error))")
        self.nativeLog("startup_failure phase=set_network_settings_failed")
        completionHandler(error)
        return
      }
      self.logger.info("setTunnelNetworkSettings completed")
      self.nativeLog("setTunnelNetworkSettings success")
      guard let tunnelFileDescriptor =
        self.networkConfiguration.tunnelFileDescriptor()
      else {
        self.logger.error(
          "startTunnel failed: tunnel file descriptor missing"
        )
        self.nativeLog("tunnel file descriptor missing")
        self.nativeLog("startup_failure phase=tunnel_fd_missing")
        completionHandler(
          PacketTunnelProviderError.couldNotDetermineFileDescriptor
        )
        return
      }
      self.logger.debug(
        "startTunnel fileDescriptor=\(tunnelFileDescriptor, privacy: .public)"
      )
      self.eventQueue.start()
      self.didStartEventQueue = true
      let initParams = self.sharedStateStore.makeInitParams()
      let setupParams = self.sharedStateStore.loadSetupParams()
      self.logger.info("quickSetup begin")
      self.nativeLog("quickSetup begin setupParamsPresent=\(!setupParams.isEmpty)")
      guard self.setupBarrier.beginSetup() else { return }
      NECoreBridge.quickSetup(
        withInitParams: initParams,
        setupParams: setupParams
      ) { result in
        self.lifecycleQueue.async {
        self.setupBarrier.finishSetup()
        guard self.generation == attempt, self.pendingStart != nil else { return }
        if let result,
          !result.isEmpty
        {
          let message = String(data: result, encoding: .utf8) ??
            "unknown core error"
          self.logger.error(
            "quickSetup failed: \(message, privacy: .public)"
          )
          self.nativeLog("quickSetup failed message=\(self.safeCoreMessage(message))")
          self.nativeLog("startup_failure phase=quick_setup_failed response_bytes=\(result.count)")
          self.rollbackPartialStart(reason: "quick_setup_failed")
          completionHandler(PacketTunnelProviderError.couldNotStartCoreTun)
          return
        }
        self.logger.info("quickSetup completed")
        self.nativeLog("quickSetup success")
        let coreTunOptions = CoreTunOptions(
          stack: vpnOptions.stack,
          address: self.networkConfiguration.tunAddress(for: vpnOptions),
          dns: self.networkConfiguration.tunDNS(for: vpnOptions),
          mtu: vpnOptions.mtu,
          disableIcmpForwarding: vpnOptions.disableIcmpForwarding,
          endpointIndependentNat: vpnOptions.endpointIndependentNat
        )
        guard let coreTunOptionsData = try? JSONEncoder().encode(coreTunOptions)
        else {
          self.nativeLog("startup_failure phase=tun_options_encoding_failed")
          self.rollbackPartialStart(reason: "tun_options_encoding_failed")
          completionHandler(PacketTunnelProviderError.couldNotStartCoreTun)
          return
        }
        let started = NECoreBridge.startTun(
          withFileDescriptor: tunnelFileDescriptor,
          options: coreTunOptionsData
        )
        self.logger.info(
          "NECoreBridge.startTun result=\(started, privacy: .public)"
        )
        self.nativeLog("startTun result=\(started)")
        if started {
          self.didStartTun = true
          self.mailbox.start()
          self.sharedStateStore.saveRunTime()
          self.resourceHeartbeat.start()
        } else {
          self.nativeLog("startup_failure phase=start_tun_failed result=failure")
          self.rollbackPartialStart(reason: "start_tun_failed")
        }
        completionHandler(
          started ? nil : PacketTunnelProviderError.couldNotStartCoreTun
        )
        }
      }
      }
    }
  }

  override func stopTunnel(
    with reason: NEProviderStopReason,
    completionHandler: @escaping () -> Void
  ) {
    // Register the system completion and its deadline before entering the
    // lifecycle queue. The queue may be blocked by an extension callback.
    setupBarrier.stop(completionHandler)
    lifecycleQueue.async {
      self.finishStop(reason: reason)
    }
  }

  private func finishStop(reason: NEProviderStopReason) {
    generation &+= 1
    let pending = pendingStart
    pendingStart = nil
    pending?(PacketTunnelProviderError.startCancelled)
    logger.info("stopTunnel reason=\(reason.rawValue, privacy: .public)")
    nativeLog("stopTunnel reason=\(reason.rawValue)")
    sharedStateStore.clearRunTime()
    reloadControlWidget()
    eventQueue.stop()
    mailbox.stop()
    didStartEventQueue = false
    resourceHeartbeat.stop()
    didStartTun = false
  }

  override func handleAppMessage(
    _ messageData: Data,
    completionHandler: ((Data?) -> Void)?
  ) {
    logger.debug(
      "handleAppMessage bytes=\(messageData.count, privacy: .public)"
    )
    guard let completionHandler else { return }
    lifecycleQueue.async {
      guard self.didStartTun else { completionHandler(nil); return }
      self.mailbox.handle(messageData, completion: completionHandler)
    }
  }

  override func sleep(completionHandler: @escaping () -> Void) {
    lifecycleQueue.async {
    if self.didStartTun && self.suspendSupport {
      self.logger.info("sleep: suspending tunnel")
      self.nativeLog("sleep suspending=true")
      NECoreBridge.setSuspended(true)
    }
    completionHandler()
    }
  }

  override func wake() {
    lifecycleQueue.async {
    if self.didStartTun && self.suspendSupport {
      self.logger.info("wake: resuming tunnel")
      self.nativeLog("wake suspended=false")
      NECoreBridge.setSuspended(false)
    }
    }
  }

  private func methodErrorResponse(
    messageData: Data,
    code: String,
    message: String
  ) -> Data? {
    var payload: [String: Any] = [
      "result": NSNull(),
      "error": [
        "code": code,
        "message": message,
        "details": NSNull(),
      ],
    ]
    if let id = methodCallID(messageData) {
      payload["id"] = id
    }
    return try? JSONSerialization.data(withJSONObject: payload)
  }

  private func methodCallID(_ messageData: Data) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: messageData)
      as? [String: Any]
    else {
      return nil
    }
    return object["id"] as? String
  }

  private func reloadControlWidget() {
    if #available(iOS 18.0, *) {
      ControlCenter.shared.reloadControls(
        ofKind: PacketTunnelEnvironment.widgetIdentifier
      )
    }
  }

  private func nativeLog(_ message: String) {
    NativeDiagnosticLog.shared.append(message)
  }

  private func rollbackPartialStart(reason: String) {
    nativeLog("rollback reason=\(reason) eventQueue=\(didStartEventQueue) tun=\(didStartTun)")
    sharedStateStore.clearRunTime()
    resourceHeartbeat.stop()
    if didStartEventQueue {
      eventQueue.stop()
      mailbox.stop()
      didStartEventQueue = false
    }
    didStartTun = false
    // The barrier owns core cleanup so rollback and external stop cannot issue
    // duplicate shutdown/stopTun pairs.
    setupBarrier.stop {}
  }

  private func safeError(_ error: Error) -> String {
    let value = error as NSError
    return "domain=\(value.domain) code=\(value.code)"
  }

  private func safeCoreMessage(_ message: String) -> String {
    var value = message
    for key in ["password", "token", "authorization", "private-key", "uuid"] {
      value = value.replacingOccurrences(
        of: "(?i)(\(key)\\s*[:=]\\s*)[^,\\s}]+",
        with: "$1[REDACTED]",
        options: .regularExpression
      )
    }
    return String(value.prefix(1024))
  }
}

// BEGIN RPC LIFECYCLE UNIT
// Joins the shutdown bridge reply with completion of local TUN retirement.
// Either signal may arrive first; duplicate bridge replies and stop signals are
// ignored, while a missing bridge reply deliberately leaves the system deadline
// as the only completion path.
final class CoreShutdownCleanupGate {
  private let lock = NSLock()
  private var shutdownResult: Bool?
  private var stopTunFinished = false
  private var resolved = false
  private let completion: (Bool) -> Void

  init(completion: @escaping (Bool) -> Void) {
    self.completion = completion
  }

  func receiveShutdownResult(_ success: Bool) {
    resolveIfReady(shutdownResult: success, didStopTun: false)
  }

  func didStopTun() {
    resolveIfReady(shutdownResult: nil, didStopTun: true)
  }

  private func resolveIfReady(shutdownResult result: Bool?, didStopTun: Bool) {
    let resolvedResult: Bool? = withLock {
      guard !resolved else { return nil }
      if shutdownResult == nil, let result { shutdownResult = result }
      if didStopTun { stopTunFinished = true }
      guard stopTunFinished, let shutdownResult else { return nil }
      resolved = true
      return shutdownResult
    }
    if let resolvedResult { completion(resolvedResult) }
  }

  private func withLock<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}

// Thread-safe, one-way retirement gate. The first stop permanently prevents
// setup; system completions have a deadline independent of provider queues.
final class CoreSetupStopBarrier {
  typealias TimeoutScheduler = (TimeInterval, @escaping () -> Void) -> Void

  static let providerStopDeadline: TimeInterval = 4
  private static let stopCompletionQueue = DispatchQueue(
    label: "com.follow.clash.ne.stop-completion",
    qos: .utility
  )

  static func scheduleStopDeadline(
    _ delay: TimeInterval,
    _ completion: @escaping () -> Void
  ) {
    stopCompletionQueue.asyncAfter(deadline: .now() + delay, execute: completion)
  }

  private let lock = NSLock()
  private var setupOutstanding = false
  private var retired = false
  private var cleanupStarted = false
  private var cleanupFinished = false
  private var completionResolved = false
  private var completions: [() -> Void] = []
  private let cleanup: (@escaping (Bool) -> Void) -> Void
  private let cleanupTimeout: TimeInterval
  private let scheduleTimeout: TimeoutScheduler
  private let diagnostic: (String) -> Void

  init(
    cleanup: @escaping (@escaping (Bool) -> Void) -> Void,
    cleanupTimeout: TimeInterval,
    scheduleTimeout: @escaping TimeoutScheduler,
    diagnostic: @escaping (String) -> Void
  ) {
    self.cleanup = cleanup
    self.cleanupTimeout = cleanupTimeout
    self.scheduleTimeout = scheduleTimeout
    self.diagnostic = diagnostic
  }

  var canStart: Bool {
    withLock { !retired && !setupOutstanding }
  }

  func beginSetup() -> Bool {
    withLock {
      guard !retired, !setupOutstanding else { return false }
      setupOutstanding = true
      return true
    }
  }

  func finishSetup() {
    let shouldCleanup = withLock {
      guard setupOutstanding else { return false }
      setupOutstanding = false
      return claimCleanupIfReady()
    }
    if shouldCleanup { runCleanup() }
  }

  func stop(_ completion: @escaping () -> Void) {
    var completeImmediately = false
    var scheduleDeadline = false
    let shouldCleanup = withLock {
      if completionResolved {
        completeImmediately = true
      } else {
        completions.append(completion)
      }
      if !retired {
        retired = true
        scheduleDeadline = true
      }
      return claimCleanupIfReady()
    }

    if completeImmediately { completion() }
    if scheduleDeadline {
      scheduleTimeout(cleanupTimeout) { [self] in reachStopDeadline() }
    }
    if shouldCleanup { runCleanup() }
  }

  // Must be called with lock held.
  private func claimCleanupIfReady() -> Bool {
    guard retired, !setupOutstanding, !cleanupStarted else { return false }
    cleanupStarted = true
    return true
  }

  private func runCleanup() {
    cleanup { [weak self] success in self?.finishCleanup(success: success) }
  }

  private func reachStopDeadline() {
    let pending = resolveCompletions()
    guard let pending else { return }
    pending.forEach { $0() }
    diagnostic("cleanup_timeout")
  }

  private func finishCleanup(success: Bool) {
    let pending: [() -> Void]? = withLock {
      guard cleanupStarted, !cleanupFinished else { return nil }
      cleanupFinished = true
      return takeCompletionsIfUnresolved()
    }
    if !success { diagnostic("cleanup_failed") }
    pending?.forEach { $0() }
  }

  private func resolveCompletions() -> [() -> Void]? {
    withLock { takeCompletionsIfUnresolved() }
  }

  private func withLock<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  // Must be called with lock held.
  private func takeCompletionsIfUnresolved() -> [() -> Void]? {
    guard !completionResolved else { return nil }
    completionResolved = true
    let pending = completions
    completions.removeAll()
    return pending
  }
}
// END RPC LIFECYCLE UNIT

private struct CoreTunOptions: Encodable {
  let stack: String
  let address: String
  let dns: String
  let mtu: Int
  let disableIcmpForwarding: Bool
  let endpointIndependentNat: Bool
}

private enum PacketTunnelProviderError: LocalizedError {
  case startCancelled
  case missingVPNOptions
  case couldNotDetermineFileDescriptor
  case couldNotStartCoreTun

  var errorDescription: String? {
    switch self {
    case .startCancelled:
      return "tunnel start cancelled"
    case .missingVPNOptions:
      return "missing VPN options"
    case .couldNotDetermineFileDescriptor:
      return "could not determine tunnel file descriptor"
    case .couldNotStartCoreTun:
      return "could not start core TUN"
    }
  }
}
