import Foundation
import NetworkExtension
import WidgetKit
import os

final class PacketTunnelProvider: NEPacketTunnelProvider {
  private let sharedStateStore = PacketTunnelSharedStateStore()
  private let networkConfiguration = PacketTunnelNetworkConfiguration()
  private lazy var eventQueue = NECoreEventQueue(
    sharedStateStore: sharedStateStore
  )
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
    logger.info("startTunnel begin")
    nativeLog("startTunnel begin")
    sharedStateStore.clearRunTime()
    reloadControlWidget()
    guard let vpnOptions = sharedStateStore.loadVPNOptions() else {
      logger.error("startTunnel failed: missing vpn options")
      nativeLog("startTunnel failed missing_vpn_options")
      completionHandler(PacketTunnelProviderError.missingVPNOptions)
      return
    }
    logger.info(
      "startTunnel options stack=\(vpnOptions.stack, privacy: .public) ipv6=\(vpnOptions.ipv6, privacy: .public) captureDns=\(vpnOptions.captureDns, privacy: .public) systemProxy=\(vpnOptions.systemProxy, privacy: .public) suspendSupport=\(vpnOptions.suspendSupport, privacy: .public)"
    )
    nativeLog("vpnOptions loaded stack=\(vpnOptions.stack) ipv6=\(vpnOptions.ipv6) captureDns=\(vpnOptions.captureDns) systemProxy=\(vpnOptions.systemProxy) suspendSupport=\(vpnOptions.suspendSupport)")
    suspendSupport = vpnOptions.suspendSupport

    setTunnelNetworkSettings(
      networkConfiguration.makeSettings(for: vpnOptions)
    ) { error in
      if let error {
        self.logger.error(
          "setTunnelNetworkSettings failed: \(error.localizedDescription, privacy: .public)"
        )
        self.nativeLog("setTunnelNetworkSettings failed error=\(self.safeError(error))")
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
      NECoreBridge.quickSetup(
        withInitParams: initParams,
        setupParams: setupParams
      ) { result in
        if let result,
          !result.isEmpty
        {
          let message = String(data: result, encoding: .utf8) ??
            "unknown core error"
          self.logger.error(
            "quickSetup failed: \(message, privacy: .public)"
          )
          self.nativeLog("quickSetup failed")
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
          self.sharedStateStore.saveRunTime()
          self.resourceHeartbeat.start()
        } else {
          self.rollbackPartialStart(reason: "start_tun_failed")
        }
        completionHandler(
          started ? nil : PacketTunnelProviderError.couldNotStartCoreTun
        )
      }
    }
  }

  override func stopTunnel(
    with reason: NEProviderStopReason,
    completionHandler: @escaping () -> Void
  ) {
    logger.info("stopTunnel reason=\(reason.rawValue, privacy: .public)")
    nativeLog("stopTunnel reason=\(reason.rawValue)")
    sharedStateStore.clearRunTime()
    reloadControlWidget()
    eventQueue.stop()
    didStartEventQueue = false
    resourceHeartbeat.stop()
    NECoreBridge.stopTun()
    didStartTun = false
    completionHandler()
  }

  override func handleAppMessage(
    _ messageData: Data,
    completionHandler: ((Data?) -> Void)?
  ) {
    logger.debug(
      "handleAppMessage bytes=\(messageData.count, privacy: .public)"
    )
    eventQueue.markCoreResponsive()
    guard let completionHandler else {
      logger.warning("handleAppMessage ignored: missing completion handler")
      return
    }

    NECoreBridge.invokeMethod(messageData) { response in
      guard let response else {
        self.logger.warning("handleAppMessage empty core response")
        completionHandler(
          self.methodErrorResponse(
            messageData: messageData,
            code: "empty_response",
            message: "empty core response"
          )
        )
        return
      }
      self.logger.debug(
        "handleAppMessage response bytes=\(response.count, privacy: .public)"
      )
      completionHandler(response)
    }
  }

  override func sleep(completionHandler: @escaping () -> Void) {
    if suspendSupport {
      logger.info("sleep: suspending tunnel")
      nativeLog("sleep suspending=true")
      NECoreBridge.setSuspended(true)
    }
    completionHandler()
  }

  override func wake() {
    if suspendSupport {
      logger.info("wake: resuming tunnel")
      nativeLog("wake suspended=false")
      NECoreBridge.setSuspended(false)
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
      didStartEventQueue = false
    }
    NECoreBridge.stopTun()
    didStartTun = false
  }

  private func safeError(_ error: Error) -> String {
    let value = error as NSError
    return "domain=\(value.domain) code=\(value.code)"
  }
}

private struct CoreTunOptions: Encodable {
  let stack: String
  let address: String
  let dns: String
  let mtu: Int
  let disableIcmpForwarding: Bool
  let endpointIndependentNat: Bool
}

private enum PacketTunnelProviderError: LocalizedError {
  case missingVPNOptions
  case couldNotDetermineFileDescriptor
  case couldNotStartCoreTun

  var errorDescription: String? {
    switch self {
    case .missingVPNOptions:
      return "missing VPN options"
    case .couldNotDetermineFileDescriptor:
      return "could not determine tunnel file descriptor"
    case .couldNotStartCoreTun:
      return "could not start core TUN"
    }
  }
}
