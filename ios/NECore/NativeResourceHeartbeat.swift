import Darwin
import Foundation

/// Process-local liveness and resource samples independent of Flutter/RPC.
final class NativeResourceHeartbeat {
  private var timer: DispatchSourceTimer?
  private let startedAt = ProcessInfo.processInfo.systemUptime
  private var warnReported = false
  private var lastReclaimUptime: TimeInterval = 0

  /// iOS terminates a packet-tunnel provider near a ~50 MB phys_footprint.
  /// Device traces showed 47 MB peaks immediately before an external stop, so
  /// warning alone is not enough: the extension must actively shed pages.
  private static let footprintWarningMB = 35
  private static let footprintReclaimMB = 42
  /// Reclaiming walks the whole Go heap. Throttle it so a sustained plateau
  /// above the threshold cannot turn into a per-second stall.
  private static let reclaimCooldown: TimeInterval = 15

  /// Injected so the heartbeat stays unit-testable and never hard-depends on
  /// the ObjC bridge being linked into a test target.
  private let reclaim: () -> Void

  init(reclaim: @escaping () -> Void = { NECoreBridge.releaseMemory() }) {
    self.reclaim = reclaim
  }

  func start() {
    stop()
    warnReported = false
    lastReclaimUptime = 0
    let timer = DispatchSource.makeTimerSource(
      queue: DispatchQueue(label: "com.follow.clash.necore-heartbeat")
    )
    timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(200))
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      let usage = Self.resourceUsage()
      let uptimeSeconds = ProcessInfo.processInfo.systemUptime - self.startedAt
      let uptime = Int(uptimeSeconds * 1000)
      NativeDiagnosticLog.shared.append(
        "heartbeat uptime_ms=\(uptime) resident_mb=\(usage.residentMB) footprint_mb=\(usage.footprintMB) virtual_mb=\(usage.virtualMB)"
      )
      if usage.footprintMB >= Self.footprintWarningMB, !self.warnReported {
        self.warnReported = true
        NativeDiagnosticLog.shared.append(
          "memory_pressure_warning footprint_mb=\(usage.footprintMB) threshold_mb=\(Self.footprintWarningMB)"
        )
      }
      guard usage.footprintMB >= Self.footprintReclaimMB else { return }
      guard Self.shouldReclaim(
        uptimeSeconds: uptimeSeconds,
        lastReclaimUptime: self.lastReclaimUptime
      ) else { return }
      self.lastReclaimUptime = uptimeSeconds
      NativeDiagnosticLog.shared.append(
        "memory_pressure_reclaim footprint_mb=\(usage.footprintMB) threshold_mb=\(Self.footprintReclaimMB)"
      )
      self.reclaim()
      let after = Self.resourceUsage()
      NativeDiagnosticLog.shared.append(
        "memory_pressure_reclaimed footprint_mb=\(after.footprintMB)"
      )
    }
    self.timer = timer
    timer.resume()
  }

  /// First crossing always reclaims; later crossings wait out the cooldown.
  static func shouldReclaim(
    uptimeSeconds: TimeInterval,
    lastReclaimUptime: TimeInterval
  ) -> Bool {
    if lastReclaimUptime == 0 { return true }
    return uptimeSeconds - lastReclaimUptime >= reclaimCooldown
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
