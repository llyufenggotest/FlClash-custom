// Run on macOS: swiftc ios/NECore/ProviderMessageMailbox.swift test/ios_rpc/main.swift -o /tmp/ios-rpc-tests && /tmp/ios-rpc-tests
import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() { fatalError(message) }
}
func pump(_ seconds: TimeInterval = 0.1) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
var executions = 0
var callbacks: [(Data?) -> Void] = []
var responsive = 0
let server = ProviderMessageMailbox(directory: root, invoke: { _, done in
  executions += 1; callbacks.append(done)
}, markResponsive: { responsive += 1 })
server.start()
let session = try String(contentsOf: root.appendingPathComponent("current-session"), encoding: .utf8)
let directory = root.appendingPathComponent(session)
func request(_ id: String, session: String, deadline: TimeInterval = Date().timeIntervalSince1970 + 2) throws -> Data {
  try Data().write(to: root.appendingPathComponent(session).appendingPathComponent(id + ".lease"))
  return try JSONSerialization.data(withJSONObject: ["rpcVersion": 1, "session": session, "requestID": id,
    "deadline": deadline, "payload": Data(#"{"id":"original","method":"resetTraffic","arguments":null}"#.utf8).base64EncodedString()])
}
let id = UUID().uuidString
let data = try request(id, session: session)
var replies = 0
server.handle(data) { _ in replies += 1 }
pump()
try data.write(to: directory.appendingPathComponent(id + ".request"), options: .atomic)
pump()
require(executions == 1, "native plus mailbox must execute once while in flight")
callbacks[0](Data("ok".utf8)); pump()
server.handle(data) { response in require(response == Data("ok".utf8), "cached response"); replies += 1 }
pump()
require(executions == 1 && replies == 2, "completed retry must use cache")
require(responsive >= 1, "mailbox must restore event flow")
let lateID = UUID().uuidString
let late = try request(lateID, session: session)
try late.write(to: directory.appendingPathComponent(lateID + ".request"), options: .atomic)
pump()
try FileManager.default.removeItem(at: directory.appendingPathComponent(lateID + ".lease"))
callbacks[1](Data("late".utf8)); pump()
require(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(lateID + ".response").path), "cancelled late response must not be published")
let expiredID = UUID().uuidString
let expired = try request(expiredID, session: session, deadline: Date().timeIntervalSince1970 - 1)
server.handle(expired) { _ in }; pump()
require(executions == 2, "expired request must not execute")
for _ in 0..<9 { let d = try request(UUID().uuidString, session: session); server.handle(d) { _ in } }
pump()
require(executions == 10, "receiver must cap real outstanding core calls at eight")
server.stop()
for callback in callbacks.dropFirst(2) { callback(Data("stopped".utf8)) }
pump()
require(!FileManager.default.fileExists(atPath: directory.path), "stop removes session and blocks late writes")
server.start()
server.handle(data) { _ in }; pump()
require(executions == 10, "old session must never execute after restart")
server.stop()
print("IOS_RPC_BEHAVIOR_PASS: dedup, cached reply, cancellation, deadline, server admission, session, stop, event recovery")
