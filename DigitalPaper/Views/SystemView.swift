import SwiftUI
import DigitalPaperKit

@MainActor
final class SystemModel: ObservableObject {
    @Published var owner = ""
    @Published var timezone = ""
    @Published var screenshot: NSImage?
    @Published var busy = false
    @Published var error: String?

    weak var app: AppModel?
    private var client: DigitalPaperClient? { app?.client }

    func load() async {
        guard let client else { return }
        do {
            owner = try await client.owner()
            timezone = try await client.timezone()
        } catch { self.error = error.localizedDescription }
    }

    func saveOwner() async {
        guard let client else { return }
        do { try await client.setOwner(owner) } catch { self.error = error.localizedDescription }
    }

    func saveTimezone() async {
        guard let client else { return }
        do { try await client.setTimezone(timezone) } catch { self.error = error.localizedDescription }
    }

    func takeScreenshot() async {
        guard let client else { return }
        busy = true; error = nil
        do {
            let data = try await client.screenshot()
            screenshot = NSImage(data: data)
        } catch { self.error = error.localizedDescription }
        busy = false
    }

    func saveScreenshot() {
        guard let image = screenshot,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "screenshot.png"
        if panel.runModal() == .OK, let url = panel.url { try? png.write(to: url) }
    }
}

struct SystemView: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var model = SystemModel()

    var body: some View {
        Form {
            Section("Owner") {
                HStack {
                    TextField("Owner name", text: $model.owner).textFieldStyle(.roundedBorder)
                    Button("Save") { Task { await model.saveOwner() } }
                }
            }
            Section("Time Zone") {
                HStack {
                    TextField("e.g. America/Los_Angeles", text: $model.timezone).textFieldStyle(.roundedBorder)
                    Button("Save") { Task { await model.saveTimezone() } }
                }
            }
            Section("Screenshot") {
                HStack {
                    Button { Task { await model.takeScreenshot() } } label: {
                        Label("Capture", systemImage: "camera")
                    }
                    if model.busy { ProgressView().controlSize(.small) }
                    if model.screenshot != nil {
                        Button { model.saveScreenshot() } label: { Label("Save…", systemImage: "square.and.arrow.down") }
                    }
                }
                if let shot = model.screenshot {
                    Image(nsImage: shot)
                        .resizable().scaledToFit()
                        .frame(maxHeight: 400)
                        .border(Color.secondary.opacity(0.3))
                }
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.caption)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("System")
        .onAppear { model.app = app }
        .task { await model.load() }
    }
}
