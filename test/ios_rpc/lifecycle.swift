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

    var cleanup: ((Bool) -> Void)?
    var events: [String] = []
    let barrier = CoreSetupStopBarrier { completion in
      events.append("cleanup")
      cleanup = completion
    }
    precondition(barrier.beginSetup())
    barrier.stop { events.append("stop1") }
    barrier.stop { events.append("stop2") }
    precondition(events.isEmpty)
    precondition(!barrier.beginSetup())
    barrier.finishSetup()
    precondition(events == ["cleanup"])
    precondition(!barrier.beginSetup())
    cleanup?(true)
    precondition(events == ["cleanup", "stop1", "stop2"])
    cleanup?(true)
    precondition(events.count == 3)
    let previousCleanup = cleanup
    precondition(barrier.beginSetup())
    barrier.finishSetup()
    barrier.stop { events.append("stop3") }
    previousCleanup?(true)
    precondition(!events.contains("stop3"))
    cleanup?(false)
    precondition(!barrier.beginSetup())
    precondition(!events.contains("stop3"))
    print("IOS_RPC_LIFECYCLE_BEHAVIOR_PASS")
  }
}
