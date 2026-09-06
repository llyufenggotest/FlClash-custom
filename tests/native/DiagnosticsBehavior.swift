import Foundation

func expect(_ value: @autoclosure () -> Bool, _ message: String) {
  guard value() else { fatalError(message) }
}

// Suspended writer reproduces slow/unavailable storage without sleeps.
let queue = DispatchQueue(label: "diagnostics-test")
queue.suspend()
let lock = NSLock()
var batches = [String]()
let log = NativeDiagnosticLog(writerQueue: queue) { data in
  lock.lock(); defer { lock.unlock() }
  batches.append(String(decoding: data, as: UTF8.self))
}
DispatchQueue.concurrentPerform(iterations: 10000) { _ in
  log.append(String(repeating: "x", count: 4000))
}
let pending = log.pendingSnapshot()
expect(pending.records <= 128, "bounded record count")
expect(pending.bytes <= 256 * 1024, "bounded UTF-8 bytes")
expect(pending.dropped > 0, "overflow is counted")
queue.resume()
log.flushForTesting()
let text = batches.joined()
expect(text.contains("diagnostic_logs_dropped count=\(pending.dropped)"), "drop summary survives overload")
expect(batches.allSatisfy { $0.utf8.count <= 64 * 1024 }, "bounded writer batches")
expect(log.pendingSnapshot().records == 0, "drain completes")
for secret in ["password=abc", "{\"token\":\"abc def\"}", "Authorization: Bearer abc", "https://u:abc@host/x", "private-key: abc"] {
  expect(!NativeDiagnosticLog.sanitize(secret).contains("abc"), "secret leaked: \(secret)")
}
expect(NativeDiagnosticLog.sanitize(String(repeating: "🧪", count: 5000)).utf8.count <= 4096, "UTF-8 entry bound")
expect(!NativeDiagnosticLog.sanitize("hello\nforged\rline").contains("\n"), "single-line output")
expect(NativeDiagnosticLog.retainedTail(of: Data("abcdef".utf8), limit: 3).isEmpty, "no partial retained record")
let base = NativeResourceHeartbeat.baseReclaimPolicy
var policy = base
for _ in 0..<10 { policy = NativeResourceHeartbeat.nextReclaimPolicy(current: policy, yieldMB: 0) }
expect(policy.cooldown == 120, "steady-state backoff retained")
expect(!NativeResourceHeartbeat.shouldReclaim(footprintMB: 44, uptimeSeconds: 101, lastReclaimUptime: 100, policy: policy), "plateau respects backoff")
expect(NativeResourceHeartbeat.shouldReclaim(footprintMB: 48, uptimeSeconds: 102, lastReclaimUptime: 100, policy: policy), "emergency bypasses adaptive cooldown")
expect(!NativeResourceHeartbeat.shouldReclaim(footprintMB: 48, uptimeSeconds: 101, lastReclaimUptime: 100, policy: policy), "emergency remains rate limited")
expect(NativeResourceHeartbeat.nextReclaimPolicy(current: policy, yieldMB: 2) == base, "effective reclaim resets policy")
print("NECORE_DIAGNOSTICS_BEHAVIOR_PASS")
