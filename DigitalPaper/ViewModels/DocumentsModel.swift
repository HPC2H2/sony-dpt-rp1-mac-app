import Foundation
import SwiftUI
import DigitalPaperKit

@MainActor
final class DocumentsModel: ObservableObject {
    @Published var allEntries: [Entry] = []
    @Published var currentPath: String = "Document"
    @Published var isLoading = false
    @Published var error: String?
    @Published var transfer: String?   // non-nil while uploading/downloading

    private weak var app: AppModel?
    private var client: DigitalPaperClient? { app?.client }

    func bind(_ app: AppModel) { self.app = app }

    /// Direct children of the current folder, folders first.
    var visible: [Entry] {
        allEntries
            .filter { parentPath(of: $0.entryPath) == currentPath }
            .sorted { lhs, rhs in
                if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
                return lhs.entryName.localizedStandardCompare(rhs.entryName) == .orderedAscending
            }
    }

    var breadcrumbs: [String] {
        var acc: [String] = []
        var path = ""
        for component in currentPath.split(separator: "/") {
            path = path.isEmpty ? String(component) : path + "/" + component
            acc.append(path)
        }
        return acc
    }

    var canGoUp: Bool { currentPath.contains("/") }

    func goUp() {
        guard canGoUp else { return }
        currentPath = parentPath(of: currentPath)
    }

    func open(_ entry: Entry) {
        if entry.isFolder { currentPath = entry.entryPath }
    }

    func reload() async {
        guard let client else { return }
        isLoading = true; error = nil
        do { allEntries = try await client.listAll() }
        catch { self.error = error.localizedDescription }
        isLoading = false
    }

    private func currentFolderID() async throws -> String {
        guard let client else { throw DigitalPaperError.notAuthenticated }
        if let entry = allEntries.first(where: { $0.entryPath == currentPath }) { return entry.entryId }
        return try await client.objectID(path: currentPath)
    }

    // MARK: Operations

    func upload(urls: [URL]) async {
        guard let client else { return }
        do {
            let parentID = try await currentFolderID()
            for url in urls {
                let needsStop = url.startAccessingSecurityScopedResource()
                defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
                transfer = "Uploading \(url.lastPathComponent)…"
                let data = try Data(contentsOf: url)
                try await client.upload(data: data, filename: url.lastPathComponent,
                                        parentID: parentID, parentPath: currentPath)
            }
            transfer = nil
            await reload()
        } catch {
            transfer = nil
            self.error = error.localizedDescription
        }
    }

    func download(_ entry: Entry, to destination: URL) async {
        guard let client else { return }
        do {
            transfer = "Downloading \(entry.entryName)…"
            let data = try await client.download(entryID: entry.entryId)
            try data.write(to: destination)
            transfer = nil
        } catch {
            transfer = nil
            self.error = error.localizedDescription
        }
    }

    func newFolder(named name: String) async {
        guard let client, !name.isEmpty else { return }
        do {
            let parentID = try await currentFolderID()
            _ = try await client.createFolder(name: name, parentID: parentID)
            await reload()
        } catch { self.error = error.localizedDescription }
    }

    func delete(_ entry: Entry) async {
        guard let client else { return }
        do {
            if entry.isFolder { try await client.deleteFolder(folderID: entry.entryId) }
            else { try await client.delete(entryID: entry.entryId) }
            await reload()
        } catch { self.error = error.localizedDescription }
    }

    func rename(_ entry: Entry, to newName: String) async {
        guard let client, !newName.isEmpty, !entry.isFolder else { return }
        do {
            let parentID: String
            if let pid = entry.parentFolderId { parentID = pid } else { parentID = try await currentFolderID() }
            try await client.move(entryID: entry.entryId, toParentID: parentID, newName: newName)
            await reload()
        } catch { self.error = error.localizedDescription }
    }

    func move(_ entry: Entry, toFolderPath path: String) async {
        guard let client else { return }
        do {
            let destID = try await client.objectID(path: path)
            try await client.move(entryID: entry.entryId, toParentID: destID)
            await reload()
        } catch { self.error = error.localizedDescription }
    }

    func displayOnDevice(_ entry: Entry) async {
        guard let client, !entry.isFolder else { return }
        do { try await client.displayDocument(entryID: entry.entryId) }
        catch { self.error = error.localizedDescription }
    }

    /// All folder paths (for the move destination picker).
    var folderPaths: [String] {
        (["Document"] + allEntries.filter { $0.isFolder }.map { $0.entryPath })
            .sorted()
    }

    private func parentPath(of path: String) -> String {
        guard let range = path.range(of: "/", options: .backwards) else { return path }
        return String(path[path.startIndex..<range.lowerBound])
    }
}
