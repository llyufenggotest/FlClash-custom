import Foundation

final class SharedStateStore {
  private let sharedStateKey = "sharedState"
  private let setupParamsKey = "setupParams"
  private let runTimeKey = "runTime"
  private let tunnelAttemptIDKey = "tunnelAttemptID"
  private let eventQueueDirectoryName = "core-events"
  private let snapshotFileName = "shared-state.json"

  let appGroupIdentifier = "group.\(Bundle.main.bundleIdentifier!)"
  let eventNotificationName = "\(Bundle.main.bundleIdentifier!).NECore.event"

  func saveSharedState(_ data: Data) -> Bool {
    guard let userDefaults = UserDefaults(suiteName: appGroupIdentifier) else {
      return false
    }
    if let json = try? JSONSerialization.jsonObject(with: data)
      as? [String: Any],
      let setupParams = json[setupParamsKey],
      !(setupParams is NSNull),
      JSONSerialization.isValidJSONObject(setupParams),
      let setupData = try? JSONSerialization.data(withJSONObject: setupParams)
    {
      userDefaults.set(setupData, forKey: setupParamsKey)
    }
    userDefaults.set(data, forKey: sharedStateKey)
    userDefaults.synchronize()
    // A freshly launched Network Extension cannot be assumed to observe an App
    // Group UserDefaults write, so commit the same bytes to a container file.
    commitSharedStateSnapshot(data)
    return true
  }

  /// Committed copy of the exact shared-state payload. The extension reads this
  /// when the App Group suite returns nothing for its own launch.
  @discardableResult
  func commitSharedStateSnapshot(_ data: Data) -> Bool {
    guard let url = sharedStateSnapshotURL() else {
      return false
    }
    let temporaryURL = url.deletingLastPathComponent()
      .appendingPathComponent(".\(snapshotFileName).\(UUID().uuidString)")
    do {
      try data.write(to: temporaryURL, options: .atomic)
      try FileManager.default.replaceItemAtomically(at: url, with: temporaryURL)
      try? (url as NSURL).setResourceValue(
        URLFileProtection.completeUntilFirstUserAuthentication,
        forKey: .fileProtectionKey
      )
      return true
    } catch {
      try? FileManager.default.removeItem(at: temporaryURL)
      return false
    }
  }

  func sharedStateSnapshotURL() -> URL? {
    appGroupDirectory()?.appendingPathComponent(snapshotFileName)
  }

  func sharedStateData() -> Data? {
    UserDefaults(suiteName: appGroupIdentifier)?.data(forKey: sharedStateKey)
  }

  func tunnelAttemptID() -> String? {
    UserDefaults(suiteName: appGroupIdentifier)?
      .string(forKey: tunnelAttemptIDKey)
  }

  /// Startup payload handed straight to `startVPNTunnel(options:)`. The system
  /// delivers it to `startTunnel(options:)` in memory, bypassing both the App
  /// Group suite and the filesystem.
  func makeTunnelStartOptions() -> [String: NSObject] {
    var options: [String: NSObject] = [:]
    if let data = sharedStateData(),
      let text = String(data: data, encoding: .utf8)
    {
      options[sharedStateKey] = text as NSString
    }
    if let attemptID = tunnelAttemptID() {
      options[tunnelAttemptIDKey] = attemptID as NSString
    }
    return options
  }

  func loadTunnelConfiguration() -> TunnelConfiguration {
    guard let userDefaults = UserDefaults(suiteName: appGroupIdentifier),
      let data = userDefaults.data(forKey: sharedStateKey),
      let sharedState = try? JSONDecoder().decode(
        SharedStatePayload.self,
        from: data
      )
    else {
      return TunnelConfiguration()
    }
    return TunnelConfiguration(
      options: sharedState.vpnOptions?.networkExtensionOptions ??
        NetworkExtensionOptions(),
      excludeSSIDs: sharedState.excludeSSIDs ?? [],
      alwaysOn: sharedState.alwaysOn ?? false
    )
  }

  func appGroupDirectory() -> URL? {
    FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroupIdentifier
    )
  }

  func eventQueueDirectory() -> URL? {
    appGroupDirectory()?.appendingPathComponent(
      eventQueueDirectoryName,
      isDirectory: true
    )
  }

  func runTime() -> Int {
    UserDefaults(suiteName: appGroupIdentifier)?
      .integer(forKey: runTimeKey) ?? 0
  }

  @discardableResult
  func beginTunnelAttempt() -> String {
    let attemptID = UUID().uuidString.lowercased()
    UserDefaults(suiteName: appGroupIdentifier)?
      .set(attemptID, forKey: tunnelAttemptIDKey)
    return attemptID
  }
}

struct TunnelConfiguration {
  let options: NetworkExtensionOptions
  let excludeSSIDs: [String]
  let alwaysOn: Bool

  init(
    options: NetworkExtensionOptions = NetworkExtensionOptions(),
    excludeSSIDs: [String] = [],
    alwaysOn: Bool = false
  ) {
    self.options = options
    self.excludeSSIDs = excludeSSIDs
    self.alwaysOn = alwaysOn
  }
}

struct NetworkExtensionOptions {
  var includeAllNetworks = false
  var excludeLocalNetworks = true
  var excludeAPNs = true
  var excludeCellularServices = true
  var enforceRoutes = false
  var excludeDeviceCommunication = true
}

private struct SharedStatePayload: Decodable {
  let vpnOptions: VpnOptionsPayload?
  let excludeSSIDs: [String]?
  let alwaysOn: Bool?
}

private struct VpnOptionsPayload: Decodable {
  let includeAllNetworks: Bool?
  let excludeLocalNetworks: Bool?
  let excludeAPNs: Bool?
  let excludeCellularServices: Bool?
  let enforceRoutes: Bool?
  let excludeDeviceCommunication: Bool?

  var networkExtensionOptions: NetworkExtensionOptions {
    NetworkExtensionOptions(
      includeAllNetworks: includeAllNetworks ?? false,
      excludeLocalNetworks: excludeLocalNetworks ?? true,
      excludeAPNs: excludeAPNs ?? true,
      excludeCellularServices: excludeCellularServices ?? true,
      enforceRoutes: enforceRoutes ?? false,
      excludeDeviceCommunication: excludeDeviceCommunication ?? true
    )
  }
}
