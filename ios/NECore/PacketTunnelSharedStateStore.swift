import Foundation

enum PacketTunnelEnvironment {
  static let extensionBundleIdentifier = Bundle.main.bundleIdentifier!
  static let baseBundleIdentifier = String(
    extensionBundleIdentifier.dropLast(".NECore".count)
  )
  static let appGroupIdentifier = "group.\(baseBundleIdentifier)"
  static let widgetIdentifier = "\(baseBundleIdentifier).Widget"
  static let eventNotificationName =
    "\(extensionBundleIdentifier).event"
}

/// Where the extension actually obtained its startup payload, and why a load
/// failed. Recorded on device so a missing payload is never ambiguous again.
enum SharedStateSource: String {
  case options
  case defaults
  case snapshot
}

enum SharedStateFailure: String {
  case suiteUnavailable = "suite_unavailable"
  case noData = "no_data"
  case decodeFailed = "decode_failed"
}

struct SharedStateLoadResult {
  let options: PacketTunnelVPNOptions?
  let source: SharedStateSource?
  let failure: SharedStateFailure?
  let byteCount: Int
}

final class PacketTunnelSharedStateStore {
  private static let emptySetupParams = Data("{}".utf8)

  private let sharedStateKey = "sharedState"
  private let setupParamsKey = "setupParams"
  private let runTimeKey = "runTime"
  private let tunnelAttemptIDKey = "tunnelAttemptID"
  private let snapshotFileName = "shared-state.json"

  /// Startup payload delivered in memory by `startVPNTunnel(options:)`. Held for
  /// the lifetime of this start so later reads never depend on cross-process
  /// visibility of the App Group suite.
  private var startOptionsData: Data?

  func adoptStartOptions(_ options: [String: NSObject]?) {
    guard let options else {
      return
    }
    if let text = options[sharedStateKey] as? String,
      let data = text.data(using: .utf8)
    {
      startOptionsData = data
      // Repopulate the suite so every later reader agrees with this start.
      userDefaults?.set(data, forKey: sharedStateKey)
    }
    if let attemptID = options[tunnelAttemptIDKey] as? String {
      userDefaults?.set(attemptID, forKey: tunnelAttemptIDKey)
    }
  }

  /// Ordered resolution: in-memory start options, then the App Group suite,
  /// then the container snapshot committed by the app before starting.
  func loadVPNOptionsResult() -> SharedStateLoadResult {
    var lastFailure: SharedStateFailure?
    var sawSuite = false

    if let data = startOptionsData {
      if let decoded = decodeVPNOptions(data) {
        return SharedStateLoadResult(
          options: decoded,
          source: .options,
          failure: nil,
          byteCount: data.count
        )
      }
      lastFailure = .decodeFailed
    }

    if let userDefaults {
      sawSuite = true
      if let data = userDefaults.data(forKey: sharedStateKey) {
        if let decoded = decodeVPNOptions(data) {
          return SharedStateLoadResult(
            options: decoded,
            source: .defaults,
            failure: nil,
            byteCount: data.count
          )
        }
        lastFailure = .decodeFailed
      }
    }

    if let data = snapshotData() {
      if let decoded = decodeVPNOptions(data) {
        // Repopulate the suite so setup params and later reads succeed.
        userDefaults?.set(data, forKey: sharedStateKey)
        return SharedStateLoadResult(
          options: decoded,
          source: .snapshot,
          failure: nil,
          byteCount: data.count
        )
      }
      lastFailure = .decodeFailed
    }

    return SharedStateLoadResult(
      options: nil,
      source: nil,
      failure: lastFailure ?? (sawSuite ? .noData : .suiteUnavailable),
      byteCount: 0
    )
  }

  func loadVPNOptions() -> PacketTunnelVPNOptions? {
    loadVPNOptionsResult().options
  }

  private func decodeVPNOptions(_ data: Data) -> PacketTunnelVPNOptions? {
    guard let sharedState = try? JSONDecoder().decode(
      PacketTunnelSharedState.self,
      from: data
    )
    else {
      return nil
    }
    return sharedState.vpnOptions
  }

  private func snapshotData() -> Data? {
    guard let url = appGroupDirectory()?
      .appendingPathComponent(snapshotFileName)
    else {
      return nil
    }
    return try? Data(contentsOf: url)
  }

  func loadSetupParams() -> Data {
    if let data = startOptionsData,
      let params = setupParams(from: data)
    {
      return params
    }
    guard let userDefaults else {
      if let data = snapshotData(),
        let params = setupParams(from: data)
      {
        return params
      }
      return Self.emptySetupParams
    }
    if let data = userDefaults.data(forKey: setupParamsKey) {
      return data
    }
    if let sharedStateData = userDefaults.data(forKey: sharedStateKey),
      let params = setupParams(from: sharedStateData)
    {
      userDefaults.set(params, forKey: setupParamsKey)
      return params
    }
    if let data = snapshotData(),
      let params = setupParams(from: data)
    {
      userDefaults.set(params, forKey: setupParamsKey)
      return params
    }
    return Self.emptySetupParams
  }

  private func setupParams(from sharedStateData: Data) -> Data? {
    guard let json = try? JSONSerialization.jsonObject(with: sharedStateData)
      as? [String: Any],
      let setupParams = json[setupParamsKey],
      !(setupParams is NSNull),
      JSONSerialization.isValidJSONObject(setupParams),
      let data = try? JSONSerialization.data(withJSONObject: setupParams)
    else {
      return nil
    }
    return data
  }

  func makeInitParams() -> String {
    let homeDirectory = appGroupDirectory()?.path ?? ""
    return "{\"home-dir\":\"\(homeDirectory)\",\"version\":0}"
  }

  func appGroupDirectory() -> URL? {
    FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier:
        PacketTunnelEnvironment.appGroupIdentifier
    )
  }

  func saveRunTime() {
    let milliseconds = Int(Date().timeIntervalSince1970 * 1000)
    userDefaults?.set(milliseconds, forKey: runTimeKey)
  }

  func clearRunTime() {
    userDefaults?.removeObject(forKey: runTimeKey)
  }

  private var userDefaults: UserDefaults? {
    UserDefaults(
      suiteName: PacketTunnelEnvironment.appGroupIdentifier
    )
  }
}

private struct PacketTunnelSharedState: Decodable {
  let vpnOptions: PacketTunnelVPNOptions?
}

struct PacketTunnelVPNOptions: Decodable {
  let port: Int
  let ipv6: Bool
  let captureDns: Bool
  let systemProxy: Bool
  let suspendSupport: Bool
  let bypassDomain: [String]
  let stack: String
  let mtu: Int
  let routeAddress: [String]
  let disableIcmpForwarding: Bool
  let endpointIndependentNat: Bool
  let includeAllNetworks: Bool
  let excludeLocalNetworks: Bool
  let excludeAPNs: Bool
  let excludeCellularServices: Bool
  let enforceRoutes: Bool
  let excludeDeviceCommunication: Bool

  private enum CodingKeys: String, CodingKey {
    case port
    case ipv6
    case captureDns
    case systemProxy
    case suspendSupport
    case bypassDomain
    case stack
    case mtu
    case routeAddress
    case disableIcmpForwarding
    case endpointIndependentNat
    case includeAllNetworks
    case excludeLocalNetworks
    case excludeAPNs
    case excludeCellularServices
    case enforceRoutes
    case excludeDeviceCommunication
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // Every field tolerates absence. A single renamed or dropped key must never
    // turn into a total startup failure on device.
    port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 7890
    ipv6 = try container.decodeIfPresent(Bool.self, forKey: .ipv6) ?? false
    captureDns = try container.decodeIfPresent(
      Bool.self,
      forKey: .captureDns
    ) ?? true
    systemProxy = try container.decodeIfPresent(
      Bool.self,
      forKey: .systemProxy
    ) ?? true
    suspendSupport = try container.decodeIfPresent(
      Bool.self,
      forKey: .suspendSupport
    ) ?? true
    bypassDomain = try container.decodeIfPresent(
      [String].self,
      forKey: .bypassDomain
    ) ?? []
    stack = try container.decodeIfPresent(String.self, forKey: .stack) ?? "gvisor"
    mtu = try container.decodeIfPresent(Int.self, forKey: .mtu) ?? 9000
    routeAddress = try container.decodeIfPresent(
      [String].self,
      forKey: .routeAddress
    ) ?? []
    disableIcmpForwarding = try container.decodeIfPresent(
      Bool.self,
      forKey: .disableIcmpForwarding
    ) ?? false
    endpointIndependentNat = try container.decodeIfPresent(
      Bool.self,
      forKey: .endpointIndependentNat
    ) ?? false
    includeAllNetworks = try container.decodeIfPresent(
      Bool.self,
      forKey: .includeAllNetworks
    ) ?? false
    excludeLocalNetworks = try container.decodeIfPresent(
      Bool.self,
      forKey: .excludeLocalNetworks
    ) ?? true
    excludeAPNs = try container.decodeIfPresent(
      Bool.self,
      forKey: .excludeAPNs
    ) ?? true
    excludeCellularServices = try container.decodeIfPresent(
      Bool.self,
      forKey: .excludeCellularServices
    ) ?? true
    enforceRoutes = try container.decodeIfPresent(
      Bool.self,
      forKey: .enforceRoutes
    ) ?? false
    excludeDeviceCommunication = try container.decodeIfPresent(
      Bool.self,
      forKey: .excludeDeviceCommunication
    ) ?? true
  }
}
