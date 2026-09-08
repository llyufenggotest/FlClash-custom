import Foundation

/// Bounded App Group diagnostics for the Network Extension process.
/// Callers must use stable lifecycle markers and never pass configs or secrets.
@objc(NECoreNativeDiagnosticLog)
final class NativeDiagnosticLog: NSObject {
  static let shared = NativeDiagnosticLog()
  private let queue = DispatchQueue(label: "com.follow.clash.necore-diagnostics")
  private let maxBytes: UInt64 = 512 * 1024
  private let fileName = "ios-necore-native.log"
  private let tunnelAttemptIDKey = "tunnelAttemptID"

  private override init() {}

  @objc(appendCoreLogLevel:message:)
  static func appendCoreLog(level: String, message: String) {
    shared.append("core level=\(level) message=\(sanitize(message))")
  }

  func append(_ message: String) {
    queue.async { [weak self] in
      guard let self, let url = self.fileURL(),
        let data = "\(ISO8601DateFormatter().string(from: Date())) [attempt=\(self.attemptID())] [NECore] \(message)\n".data(using: .utf8)
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
        // Logging must never block tunnel startup or teardown.
      }
    }
  }

  private func fileURL() -> URL? {
    FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: PacketTunnelEnvironment.appGroupIdentifier
    )?.appendingPathComponent(fileName)
  }

  private func rotateIfNeeded(url: URL, incomingBytes: UInt64) throws {
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
    guard size + incomingBytes > maxBytes else { return }
    let data = (try? Data(contentsOf: url)) ?? Data()
    try Data(data.suffix(min(data.count, Int(maxBytes / 2)))).write(to: url, options: .atomic)
  }

  private func attemptID() -> String {
    UserDefaults(suiteName: PacketTunnelEnvironment.appGroupIdentifier)?
      .string(forKey: tunnelAttemptIDKey) ?? "none"
  }

  private static func sanitize(_ message: String) -> String {
    var value = message
    for key in ["password", "token", "authorization", "private-key", "uuid"] {
      value = value.replacingOccurrences(
        of: "(?i)(\(key)\\s*[:=]\\s*)[^,\\s}]+",
        with: "$1[REDACTED]",
        options: .regularExpression
      )
    }
    return String(value.prefix(4096))
  }
}