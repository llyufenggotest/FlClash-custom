import Foundation
import Darwin
import NetworkExtension
import UIKit
import os

@MainActor
final class TunnelController {
  private final class ProviderMessageWaiter {
    private var resumed = false
    var cancel: (() -> Void)?

    func finish(_ action: () -> Void) {
      guard !resumed else { return }
      resumed = true
      cancel = nil
      action()
    }
  }

  private let sharedStateStore: SharedStateStore
  private let managerStore: TunnelManagerStore
  private let coordinator: TunnelCoordinator

  private var tunnelStatusObserver: NSObjectProtocol?
  private var appActiveObserver: NSObjectProtocol?
  private let providerMessageTimeout: TimeInterval = 8

  /// The extension answers these on a single Go-side handler, and each in-flight
  /// request costs a live buffer inside a process that jetsam kills at roughly
  /// 48 MB phys_footprint. The 2026-08-29 22:46 traces show the app issuing 56
  /// requests in one second with 65 in flight; the queue behind them pushed p50
  /// latency to 2719 ms and drove 51 timeouts plus 45 empty replies against an
  /// 8 s budget. Admitting only a few at a time keeps the budget meaningful and
  /// caps the extension's transient allocation.
  ///
  /// Matches `delayBatchConcurrency` in core/memory_budget_ios_extension.go and
  /// `maxConcurrentDelayTests` in lib/common/constant.dart.
  private let maxInFlightProviderMessages = 8
  private var inFlightProviderMessages = 0
  private var providerMessageWaiters: [(UUID, CheckedContinuation<Void, Error>)] = []
  private var nextProviderMessageSequence: UInt64 = 0
  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.follow.clash",
    category: "TunnelController"
  )

  init(
    sharedStateStore: SharedStateStore,
    onTunnelStateChanged: @escaping (TunnelTarget) -> Void,
    onExternalStart: @escaping () -> Void,
    onExternalStop: @escaping () -> Void
  ) {
    let networkExtensionIdentifier =
      "\(Bundle.main.bundleIdentifier!).NECore"
    let managerStore = TunnelManagerStore(
      sharedStateStore: sharedStateStore,
      networkExtensionIdentifier: networkExtensionIdentifier,
      localizedDescription: "FlClash"
    )
    self.sharedStateStore = sharedStateStore
    self.managerStore = managerStore
    coordinator = TunnelCoordinator(
      managerStore: managerStore,
      onTunnelStateChanged: onTunnelStateChanged,
      onExternalStart: onExternalStart,
      onExternalStop: onExternalStop
    )
  }

  deinit {
    if let tunnelStatusObserver {
      NotificationCenter.default.removeObserver(tunnelStatusObserver)
    }
    if let appActiveObserver {
      NotificationCenter.default.removeObserver(appActiveObserver)
    }
  }

  func startObserving() {
    if tunnelStatusObserver == nil {
      tunnelStatusObserver = NotificationCenter.default.addObserver(
        forName: .NEVPNStatusDidChange,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        Task { @MainActor in
          self?.coordinator.handleTunnelStatusNotification(notification)
        }
      }
    }
    if appActiveObserver == nil {
      appActiveObserver = NotificationCenter.default.addObserver(
        forName: UIApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          self?.coordinator.requestStatusRefresh(notifyExternal: true)
        }
      }
    }
    coordinator.requestStatusRefresh(notifyExternal: false)
  }

  func start() {
    coordinator.submitTunnelRequest(target: .running)
  }

  func stop() {
    coordinator.submitTunnelRequest(target: .stopped)
  }

  func toggle(notifyExternal: Bool) {
    coordinator.toggleTunnelRequest(
      notifyExternalOnCompletion: notifyExternal
    )
  }

  func reloadOnDemandRules() async throws {
    try await coordinator.reloadOnDemandRules()
  }

  /// Suspends until a provider-message slot frees up. `@MainActor` isolation is
  /// what makes the counter safe: every mutation happens on the main actor.
  private func acquireProviderMessageSlot() async throws {
    try Task.checkCancellation()
    while inFlightProviderMessages >= maxInFlightProviderMessages {
      guard providerMessageWaiters.count < 64 else {
        throw ProviderMessageError(code: "network_extension_busy", message: "RPC queue is full")
      }
      let id = UUID()
      try await withTaskCancellationHandler(operation: {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
          providerMessageWaiters.append((id, continuation))
        }
      }, onCancel: {
        Task { @MainActor in
          if let index = self.providerMessageWaiters.firstIndex(where: { $0.0 == id }) {
            self.providerMessageWaiters.remove(at: index).1.resume(throwing: CancellationError())
          }
        }
      })
      try Task.checkCancellation()
    }
    inFlightProviderMessages += 1
  }

  private func releaseProviderMessageSlot() {
    inFlightProviderMessages = max(0, inFlightProviderMessages - 1)
    guard !providerMessageWaiters.isEmpty else { return }
    // Resume one waiter per released slot; it re-checks the counter in its own
    // loop iteration, so a spurious wake cannot over-admit.
    providerMessageWaiters.removeFirst().1.resume()
  }

  // A nil reply is ambiguous, not proof of non-execution. Both transports
  // carry the exact same session/request/deadline and use one receiver cache.
  private let emptyReplyRetryCode = "empty_response_retryable"

  func sendProviderMessage(_ data: Data) async throws -> String {
    try await acquireProviderMessageSlot()
    defer { releaseProviderMessageSlot() }
    try Task.checkCancellation()
    guard let root = sharedStateStore.providerMessageMailboxDirectory(),
      let session = try? String(contentsOf: root.appendingPathComponent("current-session"), encoding: .utf8),
      UUID(uuidString: session) != nil else {
      throw ProviderMessageError(code: "network_extension_unavailable", message: "RPC session is not ready")
    }
    let directory = root.appendingPathComponent(session)
    let id = UUID().uuidString
    let lease = directory.appendingPathComponent(id + ".lease")
    let deadline = Date().addingTimeInterval(16)
    let envelope = try JSONSerialization.data(withJSONObject: [
      "rpcVersion": 1, "session": session, "requestID": id,
      "deadline": deadline.timeIntervalSince1970, "payload": data.base64EncodedString(),
    ])
    try Data().write(to: lease, options: .atomic)
    defer {
      for ext in ["lease", "request", "processing", "response"] {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id + "." + ext))
      }
    }
    nextProviderMessageSequence &+= 1
    let sequence = nextProviderMessageSequence
    do {
      return try await sendProviderMessageAttempt(envelope, sequence: sequence, attempt: 1)
    } catch let error as ProviderMessageError
      where error.code == emptyReplyRetryCode || error.code == "network_extension_timeout" {
      try Task.checkCancellation()
      return try await sendProviderMessageViaMailbox(envelope, directory: directory, id: id, deadline: deadline)
    }
  }

  private func sendProviderMessageAttempt(
    _ data: Data,
    sequence: UInt64,
    attempt: Int
  ) async throws -> String {
    let startedAt = Date()
    // Captured locally: the closure below runs with a weak `self`, and the
    // marker must survive even if the controller is torn down mid-flight.
    let retryCode = emptyReplyRetryCode
    log("provider message begin seq=\(sequence) attempt=\(attempt) bytes=\(data.count)")
    let manager: NETunnelProviderManager?
    do {
      manager = try await managerStore.loadManager(createIfNeeded: false)
    } catch {
      throw ProviderMessageError(
        code: "network_extension_error",
        message: error.localizedDescription
      )
    }
    guard let manager,
      manager.connection.status.tunnelState == .running,
      let session = manager.connection as? NETunnelProviderSession
    else {
      throw ProviderMessageError(
        code: "network_extension_unavailable",
        message: "network extension is not running"
      )
    }

    try Task.checkCancellation()
    let waiter = ProviderMessageWaiter()
    return try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
      let timeoutWork = DispatchWorkItem { [weak self] in
        waiter.finish {
          self?.log("provider message timeout seq=\(sequence)")
          continuation.resume(
            throwing: ProviderMessageError(
              code: "network_extension_timeout",
              message: "network extension response timed out"
            )
          )
        }
      }
      waiter.cancel = {
        waiter.finish {
          timeoutWork.cancel()
          continuation.resume(throwing: CancellationError())
        }
      }
      DispatchQueue.main.asyncAfter(
        deadline: .now() + providerMessageTimeout,
        execute: timeoutWork
      )
      do {
        try Task.checkCancellation()
        try session.sendProviderMessage(data) { [weak self] response in
          Task { @MainActor in
            waiter.finish {
              timeoutWork.cancel()
              let duration = Int(Date().timeIntervalSince(startedAt) * 1000)
              guard let response,
                let message = String(data: response, encoding: .utf8)
              else {
                // Delivery is ambiguous. A running session can use the same
                // deduplicated envelope over the mailbox, never replay raw Go RPC.
                let stillRunning =
                  manager.connection.status.tunnelState == .running
                if stillRunning {
                  self?.log(
                    "provider message empty-busy seq=\(sequence) attempt=\(attempt) duration_ms=\(duration)"
                  )
                  continuation.resume(
                    throwing: ProviderMessageError(
                      code: retryCode,
                      message: "network extension busy"
                    )
                  )
                } else {
                  self?.log("provider message dropped-on-stop seq=\(sequence) duration_ms=\(duration)")
                  continuation.resume(
                    throwing: ProviderMessageError(
                      code: "network_extension_unavailable",
                      message: "tunnel stopped before response"
                    )
                  )
                }
                return
              }
              self?.log("provider message end seq=\(sequence) duration_ms=\(duration) bytes=\(response.count)")
              continuation.resume(returning: message)
            }
          }
        }
      } catch {
        waiter.finish {
          timeoutWork.cancel()
          log("provider message send failed seq=\(sequence) domain=\((error as NSError).domain) code=\((error as NSError).code)")
          continuation.resume(
            throwing: ProviderMessageError(
              code: "network_extension_error",
              message: error.localizedDescription
            )
          )
        }
      }
      }
    }, onCancel: {
      Task { @MainActor in waiter.cancel?() }
    })
  }

  private func sendProviderMessageViaMailbox(
    _ data: Data, directory: URL, id: String, deadline: Date
  ) async throws -> String {
    try Task.checkCancellation()
    let responseURL = directory.appendingPathComponent(id + ".response")
    let fd = open(directory.path, O_EVTONLY)
    guard fd >= 0 else {
      throw ProviderMessageError(code: "mailbox_unavailable", message: "RPC session ended")
    }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
    source.setCancelHandler { close(fd) }
    let waiter = ProviderMessageWaiter()
    return try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
        let timeout = DispatchWorkItem {
          waiter.finish {
            source.cancel()
            continuation.resume(throwing: ProviderMessageError(code: "network_extension_timeout", message: "RPC deadline expired"))
          }
        }
        waiter.cancel = {
          waiter.finish {
            timeout.cancel(); source.cancel()
            continuation.resume(throwing: CancellationError())
          }
        }
        let readResponse = {
          guard let response = try? Data(contentsOf: responseURL),
            let message = String(data: response, encoding: .utf8) else { return }
          waiter.finish {
            timeout.cancel(); source.cancel()
            continuation.resume(returning: message)
          }
        }
        source.setEventHandler(handler: readResponse)
        source.resume()
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow), execute: timeout)
        do {
          try Task.checkCancellation()
          try data.write(to: directory.appendingPathComponent(id + ".request"), options: .atomic)
          readResponse()
        } catch {
          waiter.finish {
            timeout.cancel(); source.cancel()
            continuation.resume(throwing: error)
          }
        }
      }
    }, onCancel: {
      Task { @MainActor in waiter.cancel?() }
    })
  }

  func isCoreActive() async -> Bool {
    do {
      let manager = try await managerStore.loadManager(createIfNeeded: false)
      return manager?.connection.status.tunnelState == .running
    } catch {
      log("isCoreActive failed: \(error.localizedDescription)")
      return false
    }
  }

  func getRunTime() async -> Int {
    guard await isCoreActive() else {
      return 0
    }
    return sharedStateStore.runTime()
  }

  private func log(_ message: String) {
    logger.debug("\(message, privacy: .public)")
    NativeDiagnosticLog.shared.append(source: "Runner.TunnelController", message: message)
  }
}
