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
    guard FileManager.default.fileExists(atPath: dylibURL.path) else { return }
    handle = dlopen(dylibURL.path, RTLD_NOW | RTLD_LOCAL)
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
  private lazy var setupBarrier = CoreSetupStopBarrier { [weak self] completion in
    guard let self else { return }
    // shutdown closes ordinary listeners too; stopTun alone only closes TUN.
    let request = Data(#"{"method":"shutdown","arguments":null}"#.utf8)
    NECoreBridge.invokeMethod(request) { data in
      self.lifecycleQueue.async {
        let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let success = object?["result"] as? Bool == true
          && (object?["error"] == nil || object?["error"] is NSNull)
        if success { NECoreBridge.stopTun() }
        completion(success)
      }
    }
  }
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
    lifecycleQueue.async {
      self.finishStop(reason: reason, completionHandler: completionHandler)
    }
  }

  private func finishStop(reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
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
    NECoreBridge.stopTun()
    didStartTun = false
    // If quickSetup is still applying configuration, wait for its callback,
    // then shutdown and confirm resource retirement before acknowledging stop.
    setupBarrier.stop(completionHandler)
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
    NECoreBridge.stopTun()
    didStartTun = false
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
// Confined to the provider lifecycle queue. Failed/missing cleanup deliberately
// keeps the barrier closed: only process teardown is safe in that condition.
final class CoreSetupStopBarrier {
  private var setupOutstanding = false
  private var stopping = false
  private var cleanupOutstanding = false
  private var cleanupFailed = false
  private var cleanupGeneration: UInt64 = 0
  private var completions: [() -> Void] = []
  private let cleanup: (@escaping (Bool) -> Void) -> Void
  init(cleanup: @escaping (@escaping (Bool) -> Void) -> Void) { self.cleanup = cleanup }
  var canStart: Bool { !setupOutstanding && !stopping }
  func beginSetup() -> Bool {
    guard canStart else { return false }
    setupOutstanding = true
    return true
  }
  func finishSetup() {
    guard setupOutstanding else { return }
    setupOutstanding = false
    driveCleanup()
  }
  func stop(_ completion: @escaping () -> Void) {
    stopping = true
    completions.append(completion)
    driveCleanup()
  }
  private func driveCleanup() {
    guard stopping, !setupOutstanding, !cleanupOutstanding, !cleanupFailed else { return }
    cleanupOutstanding = true
    cleanupGeneration &+= 1
    let attempt = cleanupGeneration
    cleanup { success in
      guard self.cleanupOutstanding, self.cleanupGeneration == attempt else { return }
      self.cleanupOutstanding = false
      guard success else { self.cleanupFailed = true; return }
      self.stopping = false
      let pending = self.completions
      self.completions.removeAll()
      pending.forEach { $0() }
    }
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
