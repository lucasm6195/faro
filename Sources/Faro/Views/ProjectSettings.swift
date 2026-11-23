import FaroCore
import SwiftUI

/// Ajustes → Proyectos: nombre, carpeta y qué se lanza en cada panel.
struct ProjectSettings: View {
    private var projects: Projects { .shared }

    var body: some View {
        Form {
            if projects.all.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Todavía no tienes proyectos").font(.headline)
                        Text("Un proyecto abre de un clic la pestaña que usas siempre en una carpeta: por ejemplo Claude a la izquierda y, a la derecha, `npm run dev` y una shell para git.")
                        Text("Para crear uno: ⌘P → «Crear proyecto para esta carpeta», o monta la pestaña a tu gusto y ⌘P → «Guardar esta pestaña como proyecto». También en Shell → Proyectos.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            ForEach(projects.all) { project in
                ProjectEditor(project: project)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ProjectEditor: View {
    let project: Project
    @State private var name = ""
    @State private var commands: [String] = []

    var body: some View {
        Section {
            TextField("Nombre", text: $name)
                .onSubmit(save)
            LabeledContent("Carpeta") {
                Text(SuggestionEngine.abbreviate(project.directory)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            ForEach(commands.indices, id: \.self) { index in
                TextField("Panel \(index + 1)", text: Binding(get: { commands[safe: index] ?? "" }, set: { commands[index] = $0 }),
                          prompt: Text("shell (vacío)"))
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(save)
            }
            HStack {
                Button("Abrir") { save(); Projects.shared.open(Projects.shared.project(project.id) ?? project) }
                Button("Guardar cambios", action: save)
                    .disabled(name == project.name && commands == project.layout.terminals.map { $0.command ?? "" })
                Spacer()
                Button("Eliminar", role: .destructive) { Projects.shared.delete(project.id) }
            }
        } header: {
            Text(project.name)
        } footer: {
            Text("Paneles en orden de lectura (de izquierda a derecha y de arriba abajo). Para cambiar cómo se reparten, monta la pestaña como quieras y usa «Guardar esta pestaña como proyecto».")
        }
        .onAppear {
            name = project.name
            commands = project.layout.terminals.map { $0.command ?? "" }
        }
    }

    private func save() {
        var updated = Projects.shared.project(project.id) ?? project
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { updated.name = trimmed }
        for (index, command) in commands.enumerated() {
            let text = command.trimmingCharacters(in: .whitespaces)
            updated.layout = updated.layout.settingCommand(text.isEmpty ? nil : text, at: index)
        }
        Projects.shared.update(updated)
    }
}
