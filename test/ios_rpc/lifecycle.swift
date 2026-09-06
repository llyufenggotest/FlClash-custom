import Foundation

@main
struct LifecycleTests {
  @MainActor static func main() async {
    var replies: [String] = []
    let rpc = ServiceRPCResponse { replies.append($0) }
    rpc.finish("deadline")
    rpc.finish("late")
    precondition(replies == ["deadline"])
    var cancellationReplies = 0
    let stopped = ServiceRPCResponse { _ in cancellationReplies += 1 }
    stopped.finish("cancelled")
    stopped.finish("deadline")
    precondition(cancellationReplies == 1)

    // Stop only cancels work whose current await is owned by the Network
    // Extension. App-core setup and query work must retain its first response.
    let cancellationScope = ServiceRPCCancellationScope()
    let appRPC = cancellationScope.register(route: .app)
    let networkExtensionRPC = cancellationScope.register(route: .networkExtension)
    let undecidedRPC = cancellationScope.register(route: nil)
    var stoppedRPCs = Set<UUID>()
    cancellationScope.cancelNetworkExtensionRequests { stoppedRPCs.insert($0) }
    precondition(stoppedRPCs == [networkExtensionRPC])
    precondition(cancellationScope.contains(appRPC))
    precondition(cancellationScope.contains(undecidedRPC))
    precondition(!cancellationScope.contains(networkExtensionRPC))

    precondition(!cancellationScope.updateRoute(undecidedRPC, route: .networkExtension))
    stoppedRPCs.insert(undecidedRPC)
    cancellationScope.remove(undecidedRPC)
    precondition(stoppedRPCs == [networkExtensionRPC, undecidedRPC])
    cancellationScope.remove(appRPC)
    precondition(cancellationScope.isEmpty)

    let firstOutcome = ProviderMessageWaiter()
    var outcomes: [String] = []
    firstOutcome.finish { outcomes.append("ne_rules_not_ready") }
    firstOutcome.cancel?()
    firstOutcome.finish { outcomes.append("rpc_cancelled") }
    precondition(outcomes == ["ne_rules_not_ready"])

    let callback = CoreCallbackResponse<String>()
    callback.resolve(.failure(CancellationError()))
    var dispatched = false
    do {
      let _: String = try await withCheckedThrowingContinuation { continuation in
        callback.install(continuation) { dispatched = true }
      }
      preconditionFailure("cancelled request succeeded")
    } catch is CancellationError {} catch { preconditionFailure("unexpected error") }
    precondition(!dispatched)
    callback.resolve(.success("late"))

    // Cancellation after bridge dispatch resumes the real waiter even when
    // the bridge never replies. Late and duplicate replies cannot resume twice.
    let inFlight = CoreCallbackResponse<String>()
    dispatched = false
    let waiter = Task { @MainActor in
      try await withTaskCancellationHandler(operation: {
        try await withCheckedThrowingContinuation { continuation in
          inFlight.install(continuation) { dispatched = true }
        }
      }, onCancel: { inFlight.resolve(.failure(CancellationError())) })
    }
    while !dispatched { await Task.yield() }
    waiter.cancel()
    do { _ = try await waiter.value; preconditionFailure("missing cancellation") }
    catch is CancellationError {} catch { preconditionFailure("unexpected error") }
    inFlight.resolve(.success("late"))
    inFlight.resolve(.success("duplicate"))

    let synchronous = CoreCallbackResponse<String>()
    let value: String = try! await withCheckedThrowingContinuation { continuation in
      synchronous.install(continuation) { synchronous.resolve(.success("sync")) }
    }
    precondition(value == "sync")
    synchronous.resolve(.failure(CancellationError()))

    // Exercise the actual subscription coordinator: cancelled lock waiters
    // neither dispatch nor take ownership after the original holder finishes.
    let coordinator = CoreNotificationCoordinator { _, _ in "{}" }
    let action: CoreNotificationAction = .start(.log)
    try! await coordinator.prepare(for: action)
    var afterWaitDispatch = false
    var enteredWait = false
    let waiting = Task { @MainActor in
      enteredWait = true
      try await coordinator.prepare(for: action)
      defer { coordinator.finish(action) }
      try Task.checkCancellation()
      afterWaitDispatch = true
    }
    while !enteredWait { await Task.yield() }
    waiting.cancel()
    do { try await waiting.value; preconditionFailure("waiter not cancelled") }
    catch is CancellationError {} catch { preconditionFailure("unexpected error") }
    coordinator.finish(action)
    try! await coordinator.prepare(for: action)
    coordinator.finish(action)
    precondition(!afterWaitDispatch)

    // A hung migration must not retain a cancelled caller either.
    let migrationReply = CoreCallbackResponse<String>()
    var migrationEntered = false
    let migrating = CoreNotificationCoordinator { _, _ in
      migrationEntered = true
      return try await withCheckedThrowingContinuation { continuation in
        migrationReply.install(continuation) {}
      }
    }
    let startData = Data(#"{"method":"startLogNotify","arguments":null}"#.utf8)
    migrating.recordSuccessfulStart(.log, data: startData, route: .app)
    migrating.setDesiredRoute(.networkExtension)
    while !migrationEntered { await Task.yield() }
    let behindMigration = Task { @MainActor in
      try await migrating.prepare(for: action)
      migrating.finish(action)
      preconditionFailure("cancelled migration waiter acquired action")
    }
    await Task.yield()
    behindMigration.cancel()
    do { try await behindMigration.value; preconditionFailure("missing cancellation") }
    catch is CancellationError {} catch { preconditionFailure("unexpected error") }
    migrationReply.resolve(.success(#"{"result":true}"#))

    // A shutdown bridge is allowed to reply inline. Cleanup completion must
    // still wait until local TUN retirement has finished, and the first bridge
    // reply wins even if later replies are duplicated or contradictory.
    var synchronousShutdownEvents: [String] = []
    let synchronousShutdown = CoreShutdownCleanupGate { success in
      synchronousShutdownEvents.append("completion:\(success)")
    }
    synchronousShutdown.receiveShutdownResult(true)
    precondition(synchronousShutdownEvents.isEmpty)
    synchronousShutdownEvents.append("stopTun")
    synchronousShutdown.didStopTun()
    synchronousShutdown.receiveShutdownResult(false)
    synchronousShutdown.didStopTun()
    precondition(synchronousShutdownEvents == ["stopTun", "completion:true"])

    var asynchronousShutdownEvents: [String] = []
    let asynchronousShutdown = CoreShutdownCleanupGate { success in
      asynchronousShutdownEvents.append("completion:\(success)")
    }
    asynchronousShutdownEvents.append("stopTun")
    asynchronousShutdown.didStopTun()
    precondition(asynchronousShutdownEvents == ["stopTun"])
    asynchronousShutdown.receiveShutdownResult(false)
    asynchronousShutdown.receiveShutdownResult(true)
    precondition(asynchronousShutdownEvents == ["stopTun", "completion:false"])

    var missingShutdownCompletions = 0
    let missingShutdown = CoreShutdownCleanupGate { _ in missingShutdownCompletions += 1 }
    missingShutdown.didStopTun()
    missingShutdown.didStopTun()
    precondition(missingShutdownCompletions == 0)

    var cleanup: ((Bool) -> Void)?
    var timers: [() -> Void] = []
    var events: [String] = []
    var diagnostics: [String] = []
    let barrier = CoreSetupStopBarrier(
      cleanup: { completion in
        events.append("cleanup")
        cleanup = completion
      },
      cleanupTimeout: 2,
      scheduleTimeout: { delay, completion in
        precondition(delay == 2)
        timers.append(completion)
      },
      diagnostic: { diagnostics.append($0) }
    )
    precondition(barrier.beginSetup())
    barrier.stop { events.append("stop1") }
    barrier.stop { events.append("stop2") }
    precondition(events.isEmpty)
    precondition(timers.count == 1)
    precondition(!barrier.beginSetup())
    barrier.finishSetup()
    precondition(events == ["cleanup"])
    precondition(!barrier.beginSetup())
    cleanup?(true)
    precondition(events == ["cleanup", "stop1", "stop2"])
    timers[0]()
    cleanup?(true)
    precondition(events.count == 3)
    precondition(diagnostics.isEmpty)
    precondition(!barrier.beginSetup())
    barrier.stop { events.append("stop3") }
    precondition(events == ["cleanup", "stop1", "stop2", "stop3"])
    precondition(events.filter { $0 == "cleanup" }.count == 1)

    var failedCleanup: ((Bool) -> Void)?
    var failureCompletions = 0
    let failedBarrier = CoreSetupStopBarrier(
      cleanup: { failedCleanup = $0 },
      cleanupTimeout: 2,
      scheduleTimeout: { _, _ in },
      diagnostic: { diagnostics.append($0) }
    )
    failedBarrier.stop { failureCompletions += 1 }
    failedCleanup?(false)
    precondition(failureCompletions == 1)
    failedCleanup?(true)
    precondition(failureCompletions == 1)
    failedBarrier.stop { failureCompletions += 1 }
    precondition(failureCompletions == 2)
    precondition(!failedBarrier.beginSetup())
    precondition(diagnostics == ["cleanup_failed"])

    var hungCleanup: ((Bool) -> Void)?
    var timeout: (() -> Void)?
    var timeoutCompletions = 0
    let timedBarrier = CoreSetupStopBarrier(
      cleanup: { hungCleanup = $0 },
      cleanupTimeout: 2,
      scheduleTimeout: { _, completion in timeout = completion },
      diagnostic: { diagnostics.append($0) }
    )
    timedBarrier.stop { timeoutCompletions += 1 }
    timedBarrier.stop { timeoutCompletions += 1 }
    precondition(hungCleanup != nil)
    precondition(timeoutCompletions == 0)
    timeout?()
    precondition(timeoutCompletions == 2)
    timeout?()
    precondition(timeoutCompletions == 2)
    precondition(!timedBarrier.beginSetup())
    hungCleanup?(true)
    precondition(timeoutCompletions == 2)
    timedBarrier.stop { timeoutCompletions += 1 }
    precondition(timeoutCompletions == 3)
    precondition(diagnostics == ["cleanup_failed", "cleanup_timeout"])

    // The system stop deadline is independent from eventual core cleanup.
    // A setup callback arriving after the deadline must still trigger cleanup
    // exactly once without completing stop a second time.
    var lateSetupCleanup: ((Bool) -> Void)?
    var lateSetupCleanupCalls = 0
    var lateSetupShutdownCalls = 0
    var lateSetupStopTunCalls = 0
    var lateSetupTimeout: (() -> Void)?
    var lateSetupStopCompletions = 0
    let lateSetupBarrier = CoreSetupStopBarrier(
      cleanup: { completion in
        lateSetupCleanupCalls += 1
        // Mirrors the provider cleanup contract: shutdown is requested and
        // stopTun is issued once when cleanup starts, even if shutdown hangs.
        lateSetupShutdownCalls += 1
        lateSetupStopTunCalls += 1
        lateSetupCleanup = completion
      },
      cleanupTimeout: 2,
      scheduleTimeout: { _, completion in lateSetupTimeout = completion },
      diagnostic: { diagnostics.append($0) }
    )
    precondition(lateSetupBarrier.beginSetup())
    lateSetupBarrier.stop { lateSetupStopCompletions += 1 }
    precondition(lateSetupCleanupCalls == 0)
    lateSetupTimeout?()
    precondition(lateSetupStopCompletions == 1)
    precondition(lateSetupCleanupCalls == 0)
    precondition(lateSetupShutdownCalls == 0)
    precondition(lateSetupStopTunCalls == 0)
    precondition(!lateSetupBarrier.beginSetup())
    lateSetupBarrier.finishSetup()
    precondition(lateSetupCleanupCalls == 1)
    precondition(lateSetupShutdownCalls == 1)
    precondition(lateSetupStopTunCalls == 1)
    precondition(lateSetupStopCompletions == 1)
    lateSetupBarrier.finishSetup()
    precondition(lateSetupCleanupCalls == 1)
    precondition(lateSetupShutdownCalls == 1)
    precondition(lateSetupStopTunCalls == 1)
    lateSetupCleanup?(true)
    lateSetupCleanup?(true)
    precondition(lateSetupStopCompletions == 1)
    precondition(lateSetupCleanupCalls == 1)
    precondition(lateSetupShutdownCalls == 1)
    precondition(lateSetupStopTunCalls == 1)
    precondition(diagnostics == ["cleanup_failed", "cleanup_timeout", "cleanup_timeout"])

    // Exercise the production DispatchQueue scheduler, not a captured timer.
    // A blocked lifecycle queue must not consume the one-second margin before
    // NetworkExtension's five-second stop limit.
    precondition(CoreSetupStopBarrier.providerStopDeadline == 4)
    let blockedLifecycleQueue = DispatchQueue(label: "test.ne.blocked-lifecycle")
    let lifecycleBlocked = DispatchSemaphore(value: 0)
    let releaseLifecycle = DispatchSemaphore(value: 0)
    blockedLifecycleQueue.async {
      lifecycleBlocked.signal()
      releaseLifecycle.wait()
    }
    precondition(lifecycleBlocked.wait(timeout: .now() + 1) == .success)
    let realDeadlineCompletion = DispatchSemaphore(value: 0)
    var realCleanupCalls = 0
    let realSchedulerBarrier = CoreSetupStopBarrier(
      cleanup: { _ in realCleanupCalls += 1 },
      cleanupTimeout: 0.05,
      scheduleTimeout: CoreSetupStopBarrier.scheduleStopDeadline,
      diagnostic: { _ in }
    )
    // PacketTunnelProvider registers stop directly before it queues finishStop.
    realSchedulerBarrier.stop { realDeadlineCompletion.signal() }
    precondition(realDeadlineCompletion.wait(timeout: .now() + 1) == .success)
    precondition(realDeadlineCompletion.wait(timeout: .now() + 0.1) == .timedOut)
    precondition(realCleanupCalls == 1)
    precondition(!realSchedulerBarrier.beginSetup())
    blockedLifecycleQueue.async {
      realSchedulerBarrier.stop { realDeadlineCompletion.signal() }
    }
    releaseLifecycle.signal()
    precondition(realDeadlineCompletion.wait(timeout: .now() + 1) == .success)
    precondition(realDeadlineCompletion.wait(timeout: .now() + 0.1) == .timedOut)
    precondition(realCleanupCalls == 1)

    // A rollback owns retirement permanently. A later system stop completes,
    // but cannot issue a second shutdown/stopTun cleanup.
    var rollbackCleanup: ((Bool) -> Void)?
    var rollbackCleanupCalls = 0
    var rollbackCompletions = 0
    let rollbackBarrier = CoreSetupStopBarrier(
      cleanup: { completion in
        rollbackCleanupCalls += 1
        rollbackCleanup = completion
      },
      cleanupTimeout: 2,
      scheduleTimeout: { _, _ in },
      diagnostic: { diagnostics.append($0) }
    )
    rollbackBarrier.stop {}
    precondition(rollbackCleanupCalls == 1)
    rollbackCleanup?(true)
    rollbackBarrier.stop { rollbackCompletions += 1 }
    precondition(rollbackCompletions == 1)
    precondition(rollbackCleanupCalls == 1)
    precondition(!rollbackBarrier.beginSetup())
    print("IOS_RPC_LIFECYCLE_BEHAVIOR_PASS")
  }
}
