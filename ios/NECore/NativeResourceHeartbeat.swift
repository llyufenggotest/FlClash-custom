import Darwin
import Foundation

/// Process-local liveness and resource samples independent of Flutter/RPC.
final class NativeResourceHeartbeat {
  private var timer: DispatchSourceTimer?
  private let startedAt = ProcessInfo.processInfo.systemUptime

  func start() {
    stop()
    let timer = DispatchSource.makeTimerSource(
      queue: DispatchQueue(label: "com.follow.clash.necore-heartbeat")
    )
    timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(200))
    timer.setEventHandler {
      let usage = Self.resourceUsage()
      let uptime = Int((ProcessInfo.processInfo.systemUptime - self.startedAt) * 1000)
      NativeDiagnosticLog.shared.append(
        "heartbeat uptime_ms=\(uptime) resident_mb=\(usage.residentMB) footprint_mb=\(usage.footprintMB) virtual_mb=\(usage.virtualMB)"
      )
    }
    self.timer = timer
    timer.resume()
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
