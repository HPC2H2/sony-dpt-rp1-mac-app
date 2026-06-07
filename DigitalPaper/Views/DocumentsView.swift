import SwiftUI
import UniformTypeIdentifiers
import DigitalPaperKit

struct DocumentsView: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var model = DocumentsModel()
    @State private var selection: Entry.ID?
    @State private var showImporter = false
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var renaming: Entry?
    @State private var renameText = ""
    @State private var moving: Entry?
    @State private var isDropTargeted = false

    private var selectedEntry: Entry? { model.visible.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            breadcrumbBar
            Divider()
            table
            if let transfer = model.transfer {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(transfer) }
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).font(.caption)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .toolbar { toolbarContent }
        .navigationTitle("Documents")
        .onAppear { model.bind(app) }
        .task { await model.reload() }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { Task { await model.upload(urls: urls) } }
        }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") { Task { await model.newFolder(named: newFolderName); newFolderName = "" } }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { if let e = renaming { Task { await model.rename(e, to: renameText) } }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .sheet(item: $moving) { entry in
            MoveSheet(entry: entry, folders: model.folderPaths) { dest in
                Task { await model.move(entry, toFolderPath: dest) }
            }
        }
    }

    // MARK: Breadcrumb

    private var breadcrumbBar: some View {
        HStack(spacing: 4) {
            Button { model.goUp() } label: { Image(systemName: "chevron.up") }
                .disabled(!model.canGoUp)
            ForEach(Array(model.breadcrumbs.enumerated()), id: \.offset) { index, path in
                if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                Button(path.split(separator: "/").last.map(String.init) ?? path) {
                    model.currentPath = path
                }
                .buttonStyle(.link)
            }
            Spacer()
            if model.isLoading { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    // MARK: Table

    private var table: some View {
        Table(model.visible, selection: $selection) {
            TableColumn("Name") { entry in
                HStack {
                    Image(systemName: entry.isFolder ? "folder.fill" : "doc.text")
                        .foregroundStyle(entry.isFolder ? Color.accentColor : .secondary)
                    Text(entry.entryName)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { model.open(entry) }
            }
            TableColumn("Size") { entry in
                Text(entry.fileSize.map { byteString(Int64($0)) } ?? "—").foregroundStyle(.secondary)
            }
            .width(90)
            TableColumn("Pages") { entry in
                Text(entry.totalPageNum.map(String.init) ?? "—").foregroundStyle(.secondary)
            }
            .width(60)
            TableColumn("Modified") { entry in
                Text(formatDate(entry.modifiedDate)).foregroundStyle(.secondary)
            }
            .width(160)
        }
        .contextMenu(forSelectionType: Entry.ID.self) { ids in
            if let entry = model.visible.first(where: { ids.contains($0.id) }) {
                contextMenu(for: entry)
            }
        } primaryAction: { ids in
            if let entry = model.visible.first(where: { ids.contains($0.id) }) { model.open(entry) }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers); return true
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3)
                    .padding(4).allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for entry: Entry) -> some View {
        if entry.isFolder {
            Button("Open") { model.open(entry) }
        } else {
            Button("Download…") { downloadPanel(entry) }
            Button("Open on Device") { Task { await model.displayOnDevice(entry) } }
            Button("Rename…") { renameText = entry.entryName; renaming = entry }
            Button("Move…") { moving = entry }
        }
        Divider()
        Button("Delete", role: .destructive) { Task { await model.delete(entry) } }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button { showImporter = true } label: { Label("Upload", systemImage: "arrow.up.doc") }
            Button { showNewFolder = true } label: { Label("New Folder", systemImage: "folder.badge.plus") }
            Button { if let e = selectedEntry, !e.isFolder { downloadPanel(e) } } label: {
                Label("Download", systemImage: "arrow.down.doc")
            }
            .disabled(selectedEntry == nil || selectedEntry?.isFolder == true)
            Button { Task { await model.reload() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
        }
    }

    // MARK: Helpers

    private func downloadPanel(_ entry: Entry) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.entryName
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.download(entry, to: url) }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.pathExtension.lowercased() == "pdf" { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if !urls.isEmpty { Task { await model.upload(urls: urls) } }
        }
    }

    private func formatDate(_ raw: String?) -> String {
        guard let raw else { return "—" }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = iso.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        guard let date else { return raw }
        let out = DateFormatter()
        out.dateStyle = .short; out.timeStyle = .short
        return out.string(from: date)
    }
}

struct MoveSheet: View {
    let entry: Entry
    let folders: [String]
    let onMove: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var destination: String = "Document"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Move “\(entry.entryName)”").font(.headline)
            Picker("Destination folder", selection: $destination) {
                ForEach(folders, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.menu)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Move") { onMove(destination); dismiss() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(20).frame(width: 420)
    }
}
