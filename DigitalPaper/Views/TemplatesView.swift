import SwiftUI
import DigitalPaperKit

@MainActor
final class TemplatesModel: ObservableObject {
    @Published var templates: [NoteTemplate] = []
    @Published var error: String?

    weak var app: AppModel?
    private var client: DigitalPaperClient? { app?.client }

    func load() async {
        guard let client else { return }
        do { templates = try await client.listTemplates() }
        catch { self.error = error.localizedDescription }
    }

    func upload(url: URL) async {
        guard let client else { return }
        do {
            let needsStop = url.startAccessingSecurityScopedResource()
            defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            let name = url.deletingPathExtension().lastPathComponent
            try await client.uploadTemplate(data: data, name: name)
            await load()
        } catch { self.error = error.localizedDescription }
    }

    func delete(_ template: NoteTemplate) async {
        guard let client, let id = template.noteTemplateId else { return }
        do { try await client.deleteTemplate(id: id); await load() }
        catch { self.error = error.localizedDescription }
    }
}

struct TemplatesView: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var model = TemplatesModel()
    @State private var showImporter = false

    var body: some View {
        VStack(spacing: 0) {
            List {
                if model.templates.isEmpty { Text("No templates").foregroundStyle(.secondary) }
                ForEach(model.templates) { template in
                    HStack {
                        Image(systemName: "doc.on.doc")
                        Text(template.templateName)
                        Spacer()
                        Button(role: .destructive) { Task { await model.delete(template) } } label: {
                            Image(systemName: "trash")
                        }.buttonStyle(.borderless)
                    }
                }
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.caption).padding(8)
            }
        }
        .navigationTitle("Templates")
        .toolbar {
            Button { showImporter = true } label: { Label("Upload Template", systemImage: "arrow.up.doc") }
        }
        .onAppear { model.app = app }
        .task { await model.load() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: false) { result in
            if case let .success(urls) = result, let url = urls.first { Task { await model.upload(url: url) } }
        }
    }
}
