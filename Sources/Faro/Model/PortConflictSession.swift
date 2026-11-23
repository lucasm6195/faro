import AppKit
import FaroCore

struct PortConflictInfo: Equatable {
    let port: Int
    /// Quién lo ocupa; nil si es un proceso del sistema o de otro usuario.
    let occupant: ListeningPort?
    let command: String
    var resolving = false
    var failed = false

    /// AirPlay del Mac escucha en el 5000 y el 7000 (el clásico choque con Flask).
    var isAirPlay: Bool { occupant?.name == "ControlCenter" }
    var canClose: Bool { occupant.map { !$0.isApp } ?? false }
}

extension TerminalSession {
    /// Al lanzar un servidor: muchos (Next.js, Vite, Expo) no fallan si el puerto está ocupado,
    /// usan otro. Se mira su salida dos veces al principio; nada más.
    func watchForPortConflict(_ command: String) {
        portCheck?.cancel()
        portConflict = nil
        guard AIAgent.detect(command: command) == nil else { return }
        portCheck = Task { [weak self] in
            for delay in [2.5, 6.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self, self.runningCommand == command, self.portConflict == nil else { return }
                self.checkPortConflict(command)
            }
        }
    }

    func checkPortConflict(_ command: String) {
        guard AIAgent.detect(command: command) == nil else { return }
        // Se mira justo al terminar o mientras sigue en marcha: aún no hay prompt debajo.
        let output = outputOfLastCommand(command, maxLines: 60, promptShown: false)
        guard let port = PortConflict.port(in: output, command: command) else { return }
        let shell = shellPid
        Task { [weak self] in
            let occupant = await Ports.shared.occupant(of: port, notUnder: shell)
            if occupant == nil {
                // Sin dueño visible: solo se avisa si de verdad hay alguien escuchando ahí.
                let busy = await Task.detached { PortScanner.isListening(port: port) }.value
                guard busy else { return }
            }
            guard let self, self.lastCommand == command else { return }
            self.portConflict = PortConflictInfo(port: port, occupant: occupant, command: command)
        }
    }

    /// Cierra lo que ocupa el puerto y vuelve a lanzar el comando (parándolo antes si sigue en marcha).
    func resolvePortConflict() {
        guard var conflict = portConflict, let occupant = conflict.occupant, conflict.canClose, !conflict.resolving else { return }
        conflict.resolving = true
        conflict.failed = false
        portConflict = conflict
        Task { [weak self] in
            guard let self else { return }
            if self.runningCommand != nil {
                self.view.send(txt: "\u{03}")
                for _ in 0..<50 where !self.atPrompt { try? await Task.sleep(for: .milliseconds(100)) }
            }
            let freed = await Ports.shared.stop(occupant)
            guard self.portConflict?.command == conflict.command else { return }
            if freed && self.atPrompt {
                self.portConflict = nil
                self.run(conflict.command)
            } else {
                conflict.resolving = false
                conflict.failed = true
                self.portConflict = conflict
            }
        }
    }
}
