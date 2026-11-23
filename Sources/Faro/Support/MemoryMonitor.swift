import Darwin
import Foundation
import os

/// Devuelve al sistema la memoria que queda retenida tras ráfagas de salida
/// (un `cat` enorme, un build ruidoso). No hace nada mientras no hay actividad:
/// sin temporizadores en reposo.
final class MemoryMonitor: Sendable {
    static let shared = MemoryMonitor()

    private struct State {
        var lastActivity = ContinuousClock.now
        var checkScheduled = false
        var baseline: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let enabled = OSAllocatedUnfairLock(initialState: true)
    private let log = Logger(subsystem: "dev.faro", category: "memoria")

    func setEnabled(_ value: Bool) { enabled.withLock { $0 = value } }

    /// Se llama desde el hilo de lectura del terminal en cada lote de salida.
    func noteActivity() {
        let schedule = state.withLock { s -> Bool in
            s.lastActivity = .now
            if s.checkScheduled { return false }
            s.checkScheduled = true
            return true
        }
        if schedule { scheduleCheck(after: .seconds(3)) }
    }

    private func scheduleCheck(after delay: Duration) {
        let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [self] in
            let idle = state.withLock { ContinuousClock.now - $0.lastActivity }
            if idle < .seconds(2) {
                scheduleCheck(after: .seconds(2))
                return
            }
            state.withLock { $0.checkScheduled = false }
            trimIfWorthIt()
        }
    }

    private func trimIfWorthIt() {
        guard enabled.withLock({ $0 }) else { return }
        let before = Self.footprint()
        let baseline = state.withLock { $0.baseline }
        guard before > baseline + 24 * 1_048_576 else { return }
        trim()
        let after = Self.footprint()
        state.withLock { $0.baseline = after }
        log.debug("Memoria liberada: \(before / 1_048_576) MB → \(after / 1_048_576) MB")
    }

    func trim() {
        malloc_zone_pressure_relief(nil, 0)
    }

    func resetBaseline() {
        let now = Self.footprint()
        state.withLock { $0.baseline = now }
    }

    /// Memoria real del proceso, la misma cifra que muestra el Monitor de Actividad.
    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// Milisegundos de CPU consumidos por el proceso desde que arrancó.
    static func cpuMilliseconds() -> Int {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let micro = Int64(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000_000
            + Int64(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec)
        return Int(micro / 1_000)
    }
}
