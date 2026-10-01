import Darwin
import Foundation

final class NativeResourceHeartbeat {
  private var timer: DispatchSourceTimer?
  private let startedAt = ProcessInfo.processInfo.systemUptime
  private var warnReported = false
  private var lastReclaimUptime: TimeInterval = 0

  private static let footprintWarningMB = 30
  private static let footprintReclaimMB = 38
  private static let reclaimCooldown: TimeInterval = 15

  private static let minEffectiveYieldMB = 2
  private static let ineffectiveStreakLimit = 3
  private static let escalatedReclaimMB = 44
  private static let maxReclaimCooldown: TimeInterval = 120
  private static let emergencyReclaimMB = 48
  private static let emergencyReclaimCooldown: TimeInterval = 2

  struct ReclaimPolicy: Equatable {
    var thresholdMB: Int
    var cooldown: TimeInterval
    var ineffectiveStreak: Int
  }

  static let baseReclaimPolicy = ReclaimPolicy(
    thresholdMB: footprintReclaimMB,
    cooldown: reclaimCooldown,
    ineffectiveStreak: 0
  )

  private var reclaimPolicy = NativeResourceHeartbeat.baseReclaimPolicy

  static func nextReclaimPolicy(
    current: ReclaimPolicy,
    yieldMB: Int
  ) -> ReclaimPolicy {
    guard yieldMB < minEffectiveYieldMB else {
      return baseReclaimPolicy
    }
    let streak = current.ineffectiveStreak + 1
    guard streak >= ineffectiveStreakLimit else {
      return ReclaimPolicy(
        thresholdMB: current.thresholdMB,
        cooldown: current.cooldown,
        ineffectiveStreak: streak
      )
    }
    return ReclaimPolicy(
      thresholdMB: max(current.thresholdMB, escalatedReclaimMB),
      cooldown: min(current.cooldown * 2, maxReclaimCooldown),
      ineffectiveStreak: streak
    )
  }

  private static let logIntervalSeconds: TimeInterval = 10
  private static let logDeltaMB = 3
  private var lastLoggedUptime: TimeInterval?
  private var lastLoggedFootprintMB: Int?

  static func shouldLogHeartbeat(
    uptimeSeconds: TimeInterval,
    footprintMB: Int,
    lastLoggedUptime: TimeInterval?,
    lastLoggedFootprintMB: Int?
  ) -> Bool {
    if footprintMB >= escalatedReclaimMB { return true }
    guard let lastLoggedFootprintMB, let lastLoggedUptime else { return true }
    if abs(footprintMB - lastLoggedFootprintMB) >= logDeltaMB { return true }
    return uptimeSeconds - lastLoggedUptime >= logIntervalSeconds
  }

  private let reclaim: () -> Void

  init(reclaim: @escaping () -> Void = { NECoreBridge.releaseMemory() }) {
    self.reclaim = reclaim
  }

  func start() {
    stop()
    warnReported = false
    lastReclaimUptime = 0
    reclaimPolicy = Self.baseReclaimPolicy
    lastLoggedUptime = nil
    lastLoggedFootprintMB = nil
    let timer = DispatchSource.makeTimerSource(
      queue: DispatchQueue(label: "com.follow.clash.necore-heartbeat")
    )
    timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(200))
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      let usage = Self.resourceUsage()
      let uptimeSeconds = ProcessInfo.processInfo.systemUptime - self.startedAt
      let uptime = Int(uptimeSeconds * 1000)
      if Self.shouldLogHeartbeat(
        uptimeSeconds: uptimeSeconds,
        footprintMB: usage.footprintMB,
        lastLoggedUptime: self.lastLoggedUptime,
        lastLoggedFootprintMB: self.lastLoggedFootprintMB
      ) {
        self.lastLoggedUptime = uptimeSeconds
        self.lastLoggedFootprintMB = usage.footprintMB
        NativeDiagnosticLog.shared.append(
          "heartbeat uptime_ms=\(uptime) resident_mb=\(usage.residentMB) footprint_mb=\(usage.footprintMB) virtual_mb=\(usage.virtualMB)"
        )
      }
      if usage.footprintMB >= Self.footprintWarningMB, !self.warnReported {
        self.warnReported = true
        NativeDiagnosticLog.shared.append(
          "memory_pressure_warning footprint_mb=\(usage.footprintMB) threshold_mb=\(Self.footprintWarningMB)"
        )
      }
      guard Self.shouldReclaim(
        footprintMB: usage.footprintMB,
        uptimeSeconds: uptimeSeconds,
        lastReclaimUptime: self.lastReclaimUptime,
        policy: self.reclaimPolicy
      ) else { return }
      self.lastReclaimUptime = uptimeSeconds
      NativeDiagnosticLog.shared.append(
        "memory_pressure_reclaim footprint_mb=\(usage.footprintMB) threshold_mb=\(self.reclaimPolicy.thresholdMB)"
      )
      self.reclaim()
      let after = Self.resourceUsage()
      let yieldMB = usage.footprintMB - after.footprintMB
      self.reclaimPolicy = Self.nextReclaimPolicy(
        current: self.reclaimPolicy,
        yieldMB: yieldMB
      )
      NativeDiagnosticLog.shared.append(
        "memory_pressure_reclaimed footprint_mb=\(after.footprintMB) yield_mb=\(yieldMB) streak=\(self.reclaimPolicy.ineffectiveStreak) next_threshold_mb=\(self.reclaimPolicy.thresholdMB) next_cooldown_s=\(Int(self.reclaimPolicy.cooldown))"
      )
    }
    self.timer = timer
    timer.resume()
  }

  static func shouldReclaim(
    footprintMB: Int,
    uptimeSeconds: TimeInterval,
    lastReclaimUptime: TimeInterval,
    policy: ReclaimPolicy
  ) -> Bool {
    if footprintMB >= emergencyReclaimMB {
      return shouldReclaim(uptimeSeconds: uptimeSeconds,
                           lastReclaimUptime: lastReclaimUptime,
                           cooldown: emergencyReclaimCooldown)
    }
    guard footprintMB >= policy.thresholdMB else { return false }
    return shouldReclaim(uptimeSeconds: uptimeSeconds,
                         lastReclaimUptime: lastReclaimUptime,
                         cooldown: policy.cooldown)
  }

  static func shouldReclaim(
    uptimeSeconds: TimeInterval,
    lastReclaimUptime: TimeInterval,
    cooldown: TimeInterval = reclaimCooldown
  ) -> Bool {
    if lastReclaimUptime == 0 { return true }
    return uptimeSeconds - lastReclaimUptime >= cooldown
  }

  func stop() {
    timer?.setEventHandler {}
    timer?.cancel()
    timer = nil
  }

  private static func resourceUsage() -> (
    residentMB: Int,
    footprintMB: Int,
    virtualMB: Int
  ) {
    var basic = mach_task_basic_info_data_t()
    var basicCount = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info_data_t>.size /
        MemoryLayout<natural_t>.size
    )
    let basicResult = withUnsafeMutablePointer(to: &basic) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
        task_info(
          mach_task_self_,
          task_flavor_t(MACH_TASK_BASIC_INFO),
          $0,
          &basicCount
        )
      }
    }

    var vm = task_vm_info_data_t()
    var vmCount = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size /
        MemoryLayout<natural_t>.size
    )
    let vmResult = withUnsafeMutablePointer(to: &vm) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
        task_info(
          mach_task_self_,
          task_flavor_t(TASK_VM_INFO),
          $0,
          &vmCount
        )
      }
    }

    let divisor: UInt64 = 1024 * 1024
    return (
      basicResult == KERN_SUCCESS ? Int(UInt64(basic.resident_size) / divisor) : -1,
      vmResult == KERN_SUCCESS ? Int(UInt64(vm.phys_footprint) / divisor) : -1,
      basicResult == KERN_SUCCESS ? Int(UInt64(basic.virtual_size) / divisor) : -1
    )
  }
}
