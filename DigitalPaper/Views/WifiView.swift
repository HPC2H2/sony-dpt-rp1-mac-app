import SwiftUI
import DigitalPaperKit

@MainActor
final class WifiModel: ObservableObject {
    @Published var enabled = false
    @Published var known: [WifiAccessPoint] = []
    @Published var scanned: [WifiAccessPoint] = []
    @Published var busy = false
    @Published var error: String?

    weak var app: AppModel?
    private var client: DigitalPaperClient? { app?.client }

    func load() async {
        guard let client else { return }
        do {
            enabled = try await client.wifiEnabled()
            known = try await client.listWifi()
        } catch { self.error = error.localizedDescription }
    }

    func toggle(_ on: Bool) async {
        guard let client else { return }
        do { try await client.setWifi(enabled: on); enabled = on }
        catch { self.error = error.localizedDescription }
    }

    func scan() async {
        guard let client else { return }
        busy = true; error = nil
        do { scanned = try await client.scanWifi() }
        catch { self.error = error.localizedDescription }
        busy = false
    }

    func add(ssid: String, security: String, passphrase: String) async {
        guard let client else { return }
        do { try await client.addWifi(ssid: ssid, security: security, passphrase: passphrase); await load() }
        catch { self.error = error.localizedDescription }
    }

    func delete(_ ap: WifiAccessPoint) async {
        guard let client else { return }
        do { try await client.deleteWifi(ssidBase64: ap.ssid, security: ap.security ?? "psk"); await load() }
        catch { self.error = error.localizedDescription }
    }
}

struct WifiView: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var model = WifiModel()
    @State private var adding: WifiAccessPoint?
    @State private var manualAdd = false

    var body: some View {
        Form {
            Section {
                Toggle("Wi-Fi", isOn: Binding(get: { model.enabled }, set: { v in Task { await model.toggle(v) } }))
            }

            Section("Known Networks") {
                if model.known.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(model.known) { ap in
                    HStack {
                        Image(systemName: "wifi")
                        Text(ap.displaySSID)
                        Spacer()
                        Button(role: .destructive) { Task { await model.delete(ap) } } label: {
                            Image(systemName: "trash")
                        }.buttonStyle(.borderless)
                    }
                }
            }

            Section {
                HStack {
                    Button { Task { await model.scan() } } label: { Label("Scan", systemImage: "antenna.radiowaves.left.and.right") }
                    if model.busy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button { manualAdd = true } label: { Label("Add Manually", systemImage: "plus") }
                }
                ForEach(model.scanned) { ap in
                    HStack {
                        Image(systemName: "wifi").foregroundStyle(.secondary)
                        Text(ap.displaySSID)
                        Spacer()
                        Button("Add") { adding = ap }
                    }
                }
            } header: { Text("Available Networks") }

            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.caption)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Wi-Fi")
        .onAppear { model.app = app }
        .task { await model.load() }
        .sheet(item: $adding) { ap in
            AddWifiSheet(presetSSID: ap.displaySSID, presetSecurity: ap.security ?? "psk") { ssid, sec, pass in
                Task { await model.add(ssid: ssid, security: sec, passphrase: pass) }
            }
        }
        .sheet(isPresented: $manualAdd) {
            AddWifiSheet(presetSSID: "", presetSecurity: "psk") { ssid, sec, pass in
                Task { await model.add(ssid: ssid, security: sec, passphrase: pass) }
            }
        }
    }
}

struct AddWifiSheet: View {
    let presetSSID: String
    let presetSecurity: String
    let onAdd: (String, String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var ssid: String = ""
    @State private var security: String = "psk"
    @State private var passphrase: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Wi-Fi Network").font(.headline)
            TextField("SSID", text: $ssid).textFieldStyle(.roundedBorder)
            Picker("Security", selection: $security) {
                Text("WPA/WPA2 (psk)").tag("psk")
                Text("Open (nonsec)").tag("nonsec")
            }
            if security == "psk" {
                SecureField("Password", text: $passphrase).textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") { onAdd(ssid, security, passphrase); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(ssid.isEmpty)
            }
        }
        .padding(20).frame(width: 380)
        .onAppear { ssid = presetSSID; security = presetSecurity }
    }
}
