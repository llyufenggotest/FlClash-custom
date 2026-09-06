import Foundation

/// Bounded, best-effort diagnostics only. Overflow never changes core rules.
@objc(NECoreNativeDiagnosticLog)
final class NativeDiagnosticLog: NSObject {
  static let shared = NativeDiagnosticLog()
  private let queue: DispatchQueue
  private let sink: ((Data) -> Void)?
  private let lock = NSLock()
  private var pending = [Data]()
  private var pendingBytes = 0
  private var dropped: UInt64 = 0
  private var drainScheduled = false
  private let maxBytes: UInt64 = 4 * 1024 * 1024
  private let fileName = "ios-necore-native.log"
  private let tunnelAttemptIDKey = "tunnelAttemptID"
  private static let maxPendingBytes = 256 * 1024
  private static let maxPendingRecords = 128
  private static let maxBatchBytes = 64 * 1024

  private override init() {
    queue = DispatchQueue(label: "com.follow.clash.necore-diagnostics")
    sink = nil
    super.init()
  }

  /// Test seam: exercise the same admission/drain path with a stalled writer.
  init(writerQueue: DispatchQueue, sink: @escaping (Data) -> Void) {
    queue = writerQueue
    self.sink = sink
    super.init()
  }

  @objc(appendCoreLogLevel:message:)
  static func appendCoreLog(level: String, message: String) {
    guard level.caseInsensitiveCompare("debug") != .orderedSame else { return }
    shared.append("core level=\(sanitize(level)) message=\(sanitize(message))")
  }

  func append(_ message: String) {
    // Sanitize and bound before retention, not inside an unbounded async closure.
    let record = Data("\(ISO8601DateFormatter().string(from: Date())) [attempt=\(Self.sanitize(attemptID()))] [NECore] \(Self.sanitize(message))\n".utf8)
    lock.lock()
    if pending.count >= Self.maxPendingRecords || pendingBytes + record.count > Self.maxPendingBytes {
      if dropped < UInt64.max { dropped += 1 }
    } else {
      pending.append(record)
      pendingBytes += record.count
    }
    let schedule = !drainScheduled
    drainScheduled = true
    lock.unlock()
    // Only one work item is retained regardless of producer rate.
    if schedule { queue.async { [weak self] in self?.drain() } }
  }

  private func drain() {
    while true {
      var batch = Data()
      lock.lock()
      if dropped > 0 {
        batch.append(Data("[NECore] diagnostic_logs_dropped count=\(dropped)\n".utf8))
        dropped = 0
      }
      while let first = pending.first, batch.count + first.count <= Self.maxBatchBytes {
        batch.append(first)
        pendingBytes -= first.count
        pending.removeFirst()
      }
      if batch.isEmpty {
        drainScheduled = false
        lock.unlock()
        return
      }
      lock.unlock()
      if let sink { sink(batch) } else { persist(batch) }
    }
  }

  func pendingSnapshot() -> (records: Int, bytes: Int, dropped: UInt64) {
    lock.lock(); defer { lock.unlock() }
    return (pending.count, pendingBytes, dropped)
  }

  /// Call only off writerQueue, after producers have stopped.
  func flushForTesting() { queue.sync {} }

  private func persist(_ data: Data) {
    guard let url = fileURL() else { return }
    do {
      try rotateIfNeeded(url: url, incomingBytes: UInt64(data.count))
      if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
      }
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
    } catch {
      // Best effort: no recursive logging/retry queue on storage failure.
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
    // Seek first: never load the entire historical (possibly oversized) file.
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let limit = Int(maxBytes / 2)
    try handle.seek(toOffset: size > UInt64(limit) ? size - UInt64(limit) : 0)
    let tail = try handle.read(upToCount: limit) ?? Data()
    let retained: Data
    if size > UInt64(limit) {
      if let newline = tail.firstIndex(of: 0x0A) {
        retained = Data(tail[tail.index(after: newline)...])
      } else { retained = Data() }
    } else { retained = tail }
    try retained.write(to: url, options: .atomic)
  }

  /// Retain only complete newest records, never a partial first line.
  static func retainedTail(of data: Data, limit: Int) -> Data {
    guard limit > 0 else { return Data() }
    guard data.count > limit else { return data }
    let tail = data.suffix(limit)
    guard let newline = tail.firstIndex(of: 0x0A) else { return Data() }
    let start = tail.index(after: newline)
    guard start < tail.endIndex else { return Data() }
    return Data(tail[start...])
  }

  private func attemptID() -> String {
    UserDefaults(suiteName: PacketTunnelEnvironment.appGroupIdentifier)?
      .string(forKey: tunnelAttemptIDKey) ?? "none"
  }

  /// Shared ObjC/Swift output boundary. Unknown oversized input is omitted
  /// wholesale rather than clipping through a credential before redaction.
  @objc(sanitize:)
  static func sanitize(_ message: String) -> String {
    guard message.utf8.prefix(4097).count <= 4096 else { return "[OVERSIZED LOG OMITTED]" }
    var value = message
    let patterns = [
      #"(?i)([\"']?(?:password|passwd|token|access[_-]?token|refresh[_-]?token|authorization|proxy-authorization|private-key|uuid|secret|api[_-]?key)[\"']?\s*[:=]\s*)(?:[\"'][^\"']*[\"']|[^,\r\n}]+)"#,
      #"(?i)(https?://)[^\s/@]+(?::[^\s/@]*)?@"#
    ]
    for pattern in patterns {
      value = value.replacingOccurrences(of: pattern, with: "$1[REDACTED]", options: .regularExpression)
    }
    return value.replacingOccurrences(of: "\r", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
  }
}
