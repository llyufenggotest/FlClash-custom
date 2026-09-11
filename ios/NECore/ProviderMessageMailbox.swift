import Foundation
import Darwin

/// One receiver for native IPC and the App Group fallback. All state and disk
/// publication are serialized. Leases are owned by Runner; a timeout revokes
/// publication, NOT a Go operation that has already started.
final class ProviderMessageMailbox {
  typealias Reply = (Data?) -> Void
  private struct Entry {
    let data: Data
    let deadline: TimeInterval
    var callbacks: [Reply]
    var response: Data?
    var completed = false
  }
  private let root: URL?
  private let invoke: (Data, @escaping Reply) -> Void
  private let markResponsive: () -> Void
  private let queue = DispatchQueue(label: "com.follow.clash.rpc", qos: .utility)
  private var source: DispatchSourceFileSystemObject?
  private var gc: DispatchSourceTimer?
  private var session: String?
  private var entries: [String: Entry] = [:]
  // Never release a slot on client timeout/stop: only the actual core callback
  // releases it. Hung Go handlers therefore cannot be replaced without bound.
  private var outstanding = 0
  private let maxOutstanding = 8
  private let maxEntries = 256
  private let maxBytes = 8 * 1024 * 1024
  private let maxRetainedBytes = 12 * 1024 * 1024

  init(directory: URL?, invoke: @escaping (Data, @escaping Reply) -> Void,
       markResponsive: @escaping () -> Void) {
    root = directory
    self.invoke = invoke
    self.markResponsive = markResponsive
  }

  func start() {
    queue.sync {
      guard session == nil, let root else { return }
      let fm = FileManager.default
      do {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // Never execute a previous tunnel's pending requests, even if fresh.
        for file in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
          try? fm.removeItem(at: file)
        }
        let token = UUID().uuidString
        let directory = root.appendingPathComponent(token, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        #endif
        var excluded = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { throw CocoaError(.fileReadUnknown) }
        let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
        watch.setEventHandler { [weak self] in self?.scan() }
        watch.setCancelHandler { close(fd) }
        source = watch
        session = token
        watch.resume()
        try Data(token.utf8).write(to: root.appendingPathComponent("current-session"), options: .atomic)
        // Low-frequency GC only. Request latency is driven by directory events.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.scan() }
        gc = timer; timer.resume()
      } catch {
        source?.cancel(); source = nil; session = nil
        try? fm.removeItem(at: root.appendingPathComponent("current-session"))
      }
    }
  }

  func stop() {
    queue.sync {
      source?.cancel(); source = nil
      gc?.cancel(); gc = nil
      let callbacks = entries.values.flatMap { $0.callbacks }
      entries.removeAll()
      if let root, let session {
        try? FileManager.default.removeItem(at: root.appendingPathComponent("current-session"))
        try? FileManager.default.removeItem(at: root.appendingPathComponent(session))
      }
      session = nil
      callbacks.forEach { $0(nil) }
    }
  }

  func handle(_ data: Data, completion: @escaping Reply) {
    queue.async { self.receive(data, completion: completion) }
  }

  private var directory: URL? {
    guard let root, let session else { return nil }
    return root.appendingPathComponent(session)
  }

  private func validFile(_ url: URL, limit: Int) -> Bool {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
      attrs[.type] as? FileAttributeType == .typeRegular,
      let size = attrs[.size] as? NSNumber else { return false }
    return size.intValue <= limit
  }

  private func receive(_ data: Data, completion: @escaping Reply) {
    guard data.count <= maxBytes,
      let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      envelope["rpcVersion"] as? Int == 1,
      let token = envelope["session"] as? String, token == session,
      let id = envelope["requestID"] as? String, UUID(uuidString: id) != nil,
      let deadline = envelope["deadline"] as? TimeInterval,
      deadline > Date().timeIntervalSince1970,
      deadline <= Date().timeIntervalSince1970 + 30,
      let encoded = envelope["payload"] as? String,
      let payload = Data(base64Encoded: encoded),
      let directory, validFile(directory.appendingPathComponent(id + ".lease"), limit: 0)
    else { completion(nil); return }
    if var entry = entries[id] {
      guard entry.data == payload, entry.deadline == deadline else { completion(nil); return }
      markResponsive()
      if entry.completed { completion(entry.response) }
      else if entry.callbacks.count < 4 {
        entry.callbacks.append(completion); entries[id] = entry
      } else { completion(nil) }
      return
    }
    prune()
    let method = ((try? JSONSerialization.jsonObject(with: payload)) as? [String: Any])?["method"] as? String
    // The cancellation control RPC must enter even when all eight probe slots
    // are occupied, otherwise a profile switch cannot release those probes.
    let isDelayCancellation = method == "cancelDelayTests"
    let retained = entries.values.reduce(0) { $0 + $1.data.count + ($1.response?.count ?? 0) }
    guard (outstanding < maxOutstanding || isDelayCancellation),
      outstanding < maxOutstanding + 1, entries.count < maxEntries,
      retained + payload.count <= maxRetainedBytes else {
      completion(error(payload, code: "network_extension_busy")); return
    }
    entries[id] = Entry(data: payload, deadline: deadline, callbacks: [completion])
    outstanding += 1
    markResponsive()
    invoke(payload) { response in
      self.queue.async {
        self.outstanding -= 1
        guard self.session == token, var entry = self.entries[id] else { return }
        let retained = self.entries.values.reduce(0) { $0 + $1.data.count + ($1.response?.count ?? 0) }
        if let response, retained + response.count <= self.maxRetainedBytes {
          entry.response = response
        } else {
          // Keep a small terminal result, never evict a live dedup key and replay.
          entry.response = self.error(payload, code: response == nil ? "empty_response" : "rpc_response_too_large")
        }
        entry.completed = true
        let callbacks = entry.callbacks
        entry.callbacks = []
        self.entries[id] = entry
        let valid = deadline > Date().timeIntervalSince1970 &&
          self.validFile(directory.appendingPathComponent(id + ".lease"), limit: 0)
        callbacks.forEach { $0(valid ? entry.response : nil) }
        self.prune()
      }
    }
  }

  private func error(_ payload: Data, code: String) -> Data? {
    let request = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
    return try? JSONSerialization.data(withJSONObject: ["id": request?["id"] ?? NSNull(),
      "result": NSNull(), "error": ["code": code, "message": code, "details": NSNull()]])
  }

  private func scan() {
    guard let directory else { return }
    prune()
    let fm = FileManager.default
    let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    for file in files where file.pathExtension == "request" {
      let id = file.deletingPathExtension().lastPathComponent
      guard UUID(uuidString: id) != nil, validFile(file, limit: maxBytes),
        let data = try? Data(contentsOf: file) else { try? fm.removeItem(at: file); continue }
      guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        envelope["requestID"] as? String == id else { try? fm.removeItem(at: file); continue }
      let claimed = directory.appendingPathComponent(id + ".processing")
      do { try fm.moveItem(at: file, to: claimed) } catch { continue }
      let token = session
      receive(data) { response in
        // Called on the receiver queue, including synchronous cache hits.
        defer { try? fm.removeItem(at: claimed) }
        guard self.session == token, let response,
          self.validFile(directory.appendingPathComponent(id + ".lease"), limit: 0),
          let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          envelope["requestID"] as? String == id,
          let deadline = envelope["deadline"] as? TimeInterval,
          deadline > Date().timeIntervalSince1970 else { return }
        try? response.write(to: directory.appendingPathComponent(id + ".response"), options: .atomic)
      }
    }
  }

  private func prune() {
    let now = Date().timeIntervalSince1970
    let expired = entries.compactMap { id, entry in
      entry.deadline <= now && entry.completed ? id : nil
    }
    for id in expired { entries.removeValue(forKey: id) }
    guard let directory else { return }
    let fm = FileManager.default
    for file in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
      let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
      // Covers caller death, missing leases and replies published just before
      // cancellation. Never expire a dedup key before its request deadline.
      if modified == nil || now - modified!.timeIntervalSince1970 > 30 {
        try? fm.removeItem(at: file)
      }
    }
  }
}
