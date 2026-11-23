import Foundation
import Observation

enum SplitAxis {
    /// Uno al lado del otro.
    case horizontal
    /// Uno encima del otro.
    case vertical
}

enum PaneDirection { case left, right, up, down }

@MainActor
@Observable
final class PaneSplit: Identifiable {
    let id = UUID()
    var axis: SplitAxis
    var first: PaneNode
    var second: PaneNode
    /// Parte del espacio que ocupa el primer panel (0…1).
    var fraction = 0.5

    init(axis: SplitAxis, first: PaneNode, second: PaneNode) {
        self.axis = axis
        self.first = first
        self.second = second
    }
}

@MainActor
enum PaneNode {
    case leaf(TerminalSession)
    case split(PaneSplit)

    var id: UUID {
        switch self {
        case .leaf(let s): s.id
        case .split(let s): s.id
        }
    }

    var sessions: [TerminalSession] {
        switch self {
        case .leaf(let s): [s]
        case .split(let s): s.first.sessions + s.second.sessions
        }
    }
}

/// Una pestaña: uno o varios paneles divididos, cada uno con su terminal.
@MainActor
@Observable
final class TerminalTab: Identifiable {
    let id = UUID()
    var root: PaneNode
    var focusedID: UUID
    /// Panel ampliado temporalmente a toda la pestaña (⇧⌘↩).
    var zoomedID: UUID?
    /// Proyecto que se abrió en esta pestaña, si viene de uno.
    var projectID: UUID?

    init(session: TerminalSession) {
        root = .leaf(session)
        focusedID = session.id
    }

    var sessions: [TerminalSession] { root.sessions }
    var focused: TerminalSession? { sessions.first { $0.id == focusedID } ?? sessions.first }
    var isSplit: Bool { if case .split = root { true } else { false } }
    var zoomed: TerminalSession? { zoomedID.flatMap { id in sessions.first { $0.id == id } } }

    func contains(_ session: TerminalSession) -> Bool { sessions.contains { $0 === session } }

    // MARK: Dividir y cerrar

    func split(_ target: TerminalSession, adding new: TerminalSession, axis: SplitAxis) {
        root = Self.replacing(root, target: target.id) { leaf in
            .split(PaneSplit(axis: axis, first: leaf, second: .leaf(new)))
        }
        focusedID = new.id
        zoomedID = nil
    }

    /// Quita un panel; su hermano ocupa su sitio. Devuelve false si era el único.
    func remove(_ target: TerminalSession) -> Bool {
        guard isSplit else { return false }
        let neighbour = focusedID == target.id ? (sibling(of: target.id)?.sessions.first?.id ?? nearest(to: target.id)) : nil
        root = Self.removing(root, target: target.id) ?? root
        if zoomedID == target.id { zoomedID = nil }
        if focusedID == target.id { focusedID = neighbour ?? sessions.first?.id ?? focusedID }
        return true
    }

    /// Lo que ocupará el hueco al cerrar un panel: su hermano en la división.
    private func sibling(of id: UUID) -> PaneNode? {
        func find(_ node: PaneNode) -> PaneNode? {
            guard case .split(let sp) = node else { return nil }
            if sp.first.id == id { return sp.second }
            if sp.second.id == id { return sp.first }
            return find(sp.first) ?? find(sp.second)
        }
        return find(root)
    }

    private static func replacing(_ node: PaneNode, target: UUID, with make: (PaneNode) -> PaneNode) -> PaneNode {
        switch node {
        case .leaf(let s):
            return s.id == target ? make(node) : node
        case .split(let sp):
            sp.first = replacing(sp.first, target: target, with: make)
            sp.second = replacing(sp.second, target: target, with: make)
            return node
        }
    }

    private static func removing(_ node: PaneNode, target: UUID) -> PaneNode? {
        switch node {
        case .leaf(let s):
            return s.id == target ? nil : node
        case .split(let sp):
            let a = removing(sp.first, target: target)
            let b = removing(sp.second, target: target)
            guard let a else { return b }
            guard let b else { return a }
            if a.id != sp.first.id { sp.first = a }
            if b.id != sp.second.id { sp.second = b }
            return node
        }
    }

    // MARK: Geometría

    /// Rectángulo de cada panel dentro de un cuadrado unidad.
    func frames() -> [UUID: CGRect] {
        var result: [UUID: CGRect] = [:]
        func walk(_ node: PaneNode, _ rect: CGRect) {
            switch node {
            case .leaf(let s):
                result[s.id] = rect
            case .split(let sp):
                if sp.axis == .horizontal {
                    let w = rect.width * sp.fraction
                    walk(sp.first, CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height))
                    walk(sp.second, CGRect(x: rect.minX + w, y: rect.minY, width: rect.width - w, height: rect.height))
                } else {
                    let h = rect.height * sp.fraction
                    walk(sp.first, CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h))
                    walk(sp.second, CGRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: rect.height - h))
                }
            }
        }
        walk(root, CGRect(x: 0, y: 0, width: 1, height: 1))
        return result
    }

    /// Panel vecino en una dirección (el más cercano que se solape en el otro eje).
    func neighbour(of id: UUID, _ direction: PaneDirection) -> UUID? {
        let frames = frames()
        guard let from = frames[id] else { return nil }
        let eps = 0.001
        let candidates = frames.filter { key, r in
            guard key != id else { return false }
            switch direction {
            case .left: return r.maxX <= from.minX + eps && r.maxY > from.minY + eps && r.minY < from.maxY - eps
            case .right: return r.minX >= from.maxX - eps && r.maxY > from.minY + eps && r.minY < from.maxY - eps
            case .up: return r.maxY <= from.minY + eps && r.maxX > from.minX + eps && r.minX < from.maxX - eps
            case .down: return r.minY >= from.maxY - eps && r.maxX > from.minX + eps && r.minX < from.maxX - eps
            }
        }
        return candidates.min { a, b in
            hypot(a.value.midX - from.midX, a.value.midY - from.midY) < hypot(b.value.midX - from.midX, b.value.midY - from.midY)
        }?.key
    }

    private func nearest(to id: UUID) -> UUID? {
        for direction in [PaneDirection.left, .up, .right, .down] {
            if let n = neighbour(of: id, direction) { return n }
        }
        return nil
    }

    /// Mueve el divisor más cercano al panel activo en esa dirección.
    func resize(_ id: UUID, _ direction: PaneDirection, by step: Double = 0.05) {
        let axis: SplitAxis = direction == .left || direction == .right ? .horizontal : .vertical
        let delta = direction == .right || direction == .down ? step : -step
        var target: PaneSplit?
        func find(_ node: PaneNode) -> Bool {
            switch node {
            case .leaf(let s): return s.id == id
            case .split(let sp):
                if find(sp.first) || find(sp.second) {
                    if target == nil && sp.axis == axis { target = sp }
                    return true
                }
                return false
            }
        }
        _ = find(root)
        guard let target else { return }
        target.fraction = min(0.85, max(0.15, target.fraction + delta))
    }
}
