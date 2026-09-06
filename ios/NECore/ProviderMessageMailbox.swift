import Foundation
import os

/// App Group request/response transport used only when iOS drops the native
/// `sendProviderMessage` reply after ordinary re-signing. The system-delivered
/// startup options and this shared container are already proven to work in that
/// environment, so the fallback avoids depending on the broken reply channel.
final class ProviderMessageMailbox {
  private let sharedStateStore: PacketTunnelSharedStateStore
  private let logger = Logger(
    subsystem: PacketTunnelEnvironment.extensionBundleIdentifier,
    category: "ProviderMessageMailbox"
  )
  private var timer: DispatchSourceTimer?
  private let queue = DispatchQueue(
    label: "com.follow.clash.ne-core.provider-message-mailbox",
    qos: .userInitiated
  )

  init(sharedStateStore: PacketTunnelSharedStateStore) {
    self.sharedStateStore = sharedStateStore
  }

  func start() {
    guard timer == nil else { return }
    guard let directory = sharedStateStore.providerMessageMailboxDirectory()
    else {
      logger.error("start failed: missing App Group directory")
      return
    }
    try? FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    removeStaleFiles(in: directory)
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(20))
    timer.setEventHandler { [weak self] in
      self?.processRequests(in: directory)
    }
    self.timer = timer
    timer.resume()
  }

  func stop() {
    timer?.cancel()
    timer = nil
  }

  private func processRequests(in directory: URL) {
    guard let files = try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: nil
    ) else { return }
    for requestURL in files where requestURL.pathExtension == "request" {
      let id = requestURL.deletingPathExtension().lastPathComponent
      let claimedURL = directory.appendingPathComponent("\(id).processing")
      do {
        try FileManager.default.moveItem(at: requestURL, to: claimedURL)
      } catch {
        continue
      }
      guard let request = try? Data(contentsOf: claimedURL) else {
        try? FileManager.default.removeItem(at: claimedURL)
        continue
      }
      NECoreBridge.invokeMethod(request) { response in
        defer { try? FileManager.default.removeItem(at: claimedURL) }
        guard let response else { return }
        let responseURL = directory.appendingPathComponent("\(id).response")
        try? response.write(to: responseURL, options: .atomic)
      }
    }
  }

  private func removeStaleFiles(in directory: URL) {
    guard let files = try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.contentModificationDateKey]
    ) else { return }
    let cutoff = Date().addingTimeInterval(-30)
    for file in files {
      let modified = try? file.resourceValues(
        forKeys: [.contentModificationDateKey]
      ).contentModificationDate
      if modified == nil || modified! < cutoff {
        try? FileManager.default.removeItem(at: file)
      }
    }
  }
}
