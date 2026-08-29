import Foundation
import NetworkExtension
import UIKit
import os

@MainActor
final class TunnelController {
  private final class ProviderMessageWaiter {
    private var resumed = false

    func finish(_ action: () -> Void) {
      guard !resumed else { return }
      resumed = true
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
  private var providerMessageWaiters: [CheckedContinuation<Void, Never>] = []
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
  private func acquireProviderMessageSlot() async {
    while inFlightProviderMessages >= maxInFlightProviderMessages {
      await withCheckedContinuation { continuation in
        providerMessageWaiters.append(continuation)
      }
    }
    inFlightProviderMessages += 1
  }

  private func releaseProviderMessageSlot() {
    inFlightProviderMessages = max(0, inFlightProviderMessages - 1)
    guard !providerMessageWaiters.isEmpty else { return }
    // Resume one waiter per released slot; it re-checks the counter in its own
    // loop iteration, so a spurious wake cannot over-admit.
    providerMessageWaiters.removeFirst().resume()
  }

  func sendProviderMessage(_ data: Data) async throws -> String {
    // Admission control comes first: queueing here costs one suspended task in
    // the app, whereas queueing inside the extension costs live memory in the
    // process that gets killed for using it.
    await acquireProviderMessageSlot()
    defer { releaseProviderMessageSlot() }
    nextProviderMessageSequence &+= 1
    let sequence = nextProviderMessageSequence
    let startedAt = Date()
    log("provider message begin seq=\(sequence) bytes=\(data.count)")
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

    return try await withCheckedThrowingContinuation { continuation in
      let waiter = ProviderMessageWaiter()
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
      DispatchQueue.main.asyncAfter(
        deadline: .now() + providerMessageTimeout,
        execute: timeoutWork
      )
      do {
        try session.sendProviderMessage(data) { response in
          Task { @MainActor in
            waiter.finish {
              timeoutWork.cancel()
              let duration = Int(Date().timeIntervalSince(startedAt) * 1000)
              guard let response,
                let message = String(data: response, encoding: .utf8)
              else {
                self.log("provider message empty seq=\(sequence) duration_ms=\(duration)")
                continuation.resume(
                  throwing: ProviderMessageError(
                    code: "empty_response",
                    message: "empty network extension response"
                  )
                )
                return
              }
              self.log("provider message end seq=\(sequence) duration_ms=\(duration) bytes=\(response.count)")
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
