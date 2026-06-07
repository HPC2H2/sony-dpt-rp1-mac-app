import SwiftUI
import DigitalPaperKit

struct SyncAction: Identifiable {
    enum Kind: String { case upload = "Upload", download = "Download", skip = "Up to date" }
    let id = UUID()
    let relativePath: String
    let kind: Kind
    let localURL: URL?
    let remoteEntry: Entry?
}

@MainActor
final class SyncModel: ObservableObject {
    @Published var localFolder: URL?
    @Published var remoteFolder: String = "Document"
    @Published var plan: [SyncAction] = []
    @Published var running = false
    @Published var progress: String?
    @Published var error: String?

    weak var app: AppModel?
    private var client: DigitalPaperClient? { app?.client }

    var remoteFolders: [String] = ["Document"]

    func loadRemoteFolders() async {
        guard let client else { return }
        if let all = try? await client.listAll() {
            remoteFolders = (["Document"] + all.filter { $0.isFolder }.map { $0.entryPath }).sorted()
        }
    }

    func buildPlan() async {
        guard let client, let localFolder else { return }
        error = nil; progress = "Comparing…"
        defer { progress = nil }
        do {
            let needsStop = localFolder.startAccessingSecurityScopedResource()
            defer { if needsStop { localFolder.stopAccessingSecurityScopedResource() } }

            // Local PDFs, relative paths.
            var localFiles: [String: URL] = [:]
            let fm = FileManager.default
            if let en = fm.enumerator(at: localFolder, includingPropertiesForKeys: [.contentModificationDateKey]) {
                for case let url as URL in en where url.pathExtension.lowercased() == "pdf" {
                    let rel = url.path.replacingOccurrences(of: localFolder.path + "/", with: "")
                    localFiles[rel] = url
                }
            }

            // Remote documents under remoteFolder, relative paths.
            let all = try await client.listAll()
            let prefix = remoteFolder + "/"
            var remoteFiles: [String: Entry] = [:]
            for e in all where !e.isFolder && e.entryPath.hasPrefix(prefix) {
                remoteFiles[String(e.entryPath.dropFirst(prefix.count))] = e
            }

            var actions: [SyncAction] = []
            let allKeys = Set(localFiles.keys).union(remoteFiles.keys)
            for key in allKeys.sorted() {
                let local = localFiles[key]
                let remote = remoteFiles[key]
                switch (local, remote) {
                case let (l?, nil):
                    actions.append(.init(relativePath: key, kind: .upload, localURL: l, remoteEntry: nil))
                case let (nil, r?):
                    actions.append(.init(relativePath: key, kind: .download, localURL: nil, remoteEntry: r))
                case let (l?, r?):
                    let localDate = (try? l.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    let remoteDate = parseDate(r.modifiedDate)
                    if let ld = localDate, let rd = remoteDate {
                        if ld > rd.addingTimeInterval(2) {
                            actions.append(.init(relativePath: key, kind: .upload, localURL: l, remoteEntry: r))
                        } else if rd > ld.addingTimeInterval(2) {
                            actions.append(.init(relativePath: key, kind: .download, localURL: l, remoteEntry: r))
                        } else {
                            actions.append(.init(relativePath: key, kind: .skip, localURL: l, remoteEntry: r))
                        }
                    } else {
                        actions.append(.init(relativePath: key, kind: .skip, localURL: l, remoteEntry: r))
                    }
                default: break
                }
            }
            plan = actions
        } catch { self.error = error.localizedDescription }
    }

    func run() async {
        guard let client, let localFolder else { return }
        running = true; error = nil
        defer { running = false; progress = nil }
        let needsStop = localFolder.startAccessingSecurityScopedResource()
        defer { if needsStop { localFolder.stopAccessingSecurityScopedResource() } }
        do {
            for action in plan where action.kind != .skip {
                progress = "\(action.kind.rawValue) \(action.relativePath)…"
                switch action.kind {
                case .upload:
                    guard let url = action.localURL else { continue }
                    let data = try Data(contentsOf: url)
                    let remoteDir = remoteFolder + "/" + (action.relativePath as NSString).deletingLastPathComponent
                    let cleanDir = remoteDir.hasSuffix("/") ? String(remoteDir.dropLast()) : remoteDir
                    let parentID = try await client.ensureFolder(path: cleanDir)
                    try await client.upload(data: data, filename: (action.relativePath as NSString).lastPathComponent,
                                            parentID: parentID, parentPath: cleanDir)
                case .download:
                    guard let entry = action.remoteEntry else { continue }
                    let dest = localFolder.appendingPathComponent(action.relativePath)
                    try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    let data = try await client.download(entryID: entry.entryId)
                    try data.write(to: dest)
                case .skip: break
                }
            }
            await buildPlan()
        } catch { self.error = error.localizedDescription }
    }

    private func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }
}

struct SyncView: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var model = SyncModel()

    private var pendingCount: Int { model.plan.filter { $0.kind != .skip }.count }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Folders") {
                    HStack {
                        Text("Local")
                        Spacer()
                        Text(model.localFolder?.path ?? "Choose…").foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { chooseLocal() }
                    }
                    Picker("Remote", selection: $model.remoteFolder) {
                        ForEach(model.remoteFolders, id: \.self) { Text($0).tag($0) }
                    }
                }
                Section {
                    HStack {
                        Button { Task { await model.buildPlan() } } label: { Label("Preview Changes", systemImage: "eye") }
                            .disabled(model.localFolder == nil)
                        Button { Task { await model.run() } } label: { Label("Sync \(pendingCount) item(s)", systemImage: "arrow.triangle.2.circlepath") }
                            .buttonStyle(.borderedProminent)
                            .disabled(pendingCount == 0 || model.running)
                        if model.running { ProgressView().controlSize(.small) }
                    }
                    Text("Newest version wins. Deletions are not performed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 220)

            Divider()

            Table(model.plan) {
                TableColumn("Action") { a in
                    Label(a.kind.rawValue, systemImage: icon(a.kind)).foregroundStyle(color(a.kind))
                }.width(120)
                TableColumn("File") { a in Text(a.relativePath) }
            }

            if let progress = model.progress {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(progress) }
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.caption).padding(8)
            }
        }
        .navigationTitle("Sync")
        .onAppear { model.app = app }
        .task { await model.loadRemoteFolders() }
    }

    private func chooseLocal() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { model.localFolder = panel.url }
    }

    private func icon(_ kind: SyncAction.Kind) -> String {
        switch kind {
        case .upload: return "arrow.up.circle"
        case .download: return "arrow.down.circle"
        case .skip: return "checkmark.circle"
        }
    }
    private func color(_ kind: SyncAction.Kind) -> Color {
        switch kind {
        case .upload: return .blue
        case .download: return .green
        case .skip: return .secondary
        }
    }
}
