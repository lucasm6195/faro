import AppKit
import FaroCore
import Observation

/// Puertos abiertos en este Mac (servidores de desarrollo que tú o una IA dejasteis en marcha).
/// No vigila nada en segundo plano: se lee al abrir el panel, al volver a Faro y poco después
/// de lanzar o terminar un comando. Cada lectura tarda unos milisegundos.
@MainActor
@Observable
final class Ports {
    static let shared = Ports()

    private(set) var all: [ListeningPort] = []
    private(set) var closing: Set<String> = []
    private(set) var failed: Set<String> = []
    /// Algún panel de puertos está abierto: mientras tanto se relee cada 2 s.
    var panelsOpen = 0 { didSet { if panelsOpen > 0 && oldValue == 0 { refresh(); keepFresh() } } }

    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var live: Task<Void, Never>?
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private var observer: NSObjectProtocol?

    var servers: [ListeningPort] { all.filter { !$0.isApp } }
    var apps: [ListeningPort] { all.filter(\.isApp) }

    private init() {
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Ports.shared.refresh() }
        }
    }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        let me = getpid()
        Task {
            let result = await Task.detached(priority: .utility) { DemoMode.filter(PortScanner.scan(excluding: [me])) }.value
            scanning = false
            if result != all { all = result }
            failed.formIntersection(Set(result.map(\.id)))
        }
    }

    /// Relee dentro de un rato (un servidor tarda unos segundos en abrir su puerto).
    func refresh(after delay: Duration) {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    private func keepFresh() {
        live?.cancel()
        live = Task {
            while !Task.isCancelled, panelsOpen > 0 {
                try? await Task.sleep(for: .seconds(2))
                refresh()
            }
        }
    }

    // MARK: Pestañas

    /// La terminal de Faro desde la que se lanzó, si fue desde una.
    func session(for port: ListeningPort) -> TerminalSession? {
        let parents = Set(port.parents.map(\.pid))
        for controller in AppModel.shared.windows {
            for session in controller.model.allSessions {
                guard let pid = session.shellPid, pid > 0 else { continue }
                if parents.contains(pid) || port.pid == pid { return session }
            }
        }
        return nil
    }

    // MARK: Cerrar

    /// Cierra el servidor entero (por ejemplo `npm run dev` y sus hijos): primero le pide que
    /// termine (SIGTERM) y, si a los 3 s sigue vivo, lo fuerza (SIGKILL).
    func close(_ port: ListeningPort) {
        Task { await stop(port) }
    }

    /// Cierra el servidor y espera a que su puerto quede libre. Devuelve true si lo está.
    @discardableResult
    func stop(_ port: ListeningPort) async -> Bool {
        let root = port.root
        let protected = Set(AppModel.shared.windows.flatMap(\.model.allSessions).compactMap(\.shellPid)).union([getpid(), 0, 1])
        guard !protected.contains(root) else { failed.insert(port.id); return false }
        closing.insert(port.id)
        failed.remove(port.id)
        let number = port.port
        let free = await Task.detached(priority: .userInitiated) { () -> Bool in
            let pids = [root] + PortScanner.descendants(of: root)
            for pid in pids { kill(pid, SIGTERM) }
            for _ in 0..<15 {
                try? await Task.sleep(for: .milliseconds(200))
                if !pids.contains(where: PortScanner.isAlive) { break }
            }
            for pid in pids where PortScanner.isAlive(pid) { kill(pid, SIGKILL) }
            // El puerto tarda un instante en soltarse aunque el proceso ya no exista.
            for _ in 0..<15 {
                if !PortScanner.scan().contains(where: { $0.port == number && $0.pid == port.pid }) { return true }
                try? await Task.sleep(for: .milliseconds(200))
            }
            return false
        }.value
        closing.remove(port.id)
        refresh()
        if !free { failed.insert(port.id) }
        return free
    }

    /// Quién tiene ocupado un puerto, sin contar lo que cuelga de esa terminal (su propio servidor).
    func occupant(of number: Int, notUnder shell: pid_t?) async -> ListeningPort? {
        let me = getpid()
        let found = await Task.detached(priority: .userInitiated) { DemoMode.filter(PortScanner.scan(excluding: [me])) }.value
        if found != all { all = found }
        return found.first { port in
            port.port == number && !(shell.map { s in port.pid == s || port.parents.contains { $0.pid == s } } ?? false)
        }
    }

    func closeAllServers() {
        for port in servers where !closing.contains(port.id) { close(port) }
    }
}
