import SwiftUI
import DigitalPaperKit

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.isConnected {
                MainView()
            } else {
                ConnectView()
            }
        }
        .animation(.default, value: model.isConnected)
    }
}

/// Shown when no device is connected: discovery list + manual address + import.
struct ConnectView: View {
    @EnvironmentObject var model: AppModel
    @State private var manualAddress = ""
    @State private var pairingDevice: DiscoveredDevice?
    @State private var pairingManualHost: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            List {
                Section("Discovered Devices") {
                    if model.discovered.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Searching the local network…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(model.discovered) { device in
                        deviceRow(device)
                    }
                }

                Section("Connect by Address") {
                    HStack {
                        TextField("192.168.0.x  or  digitalpaper.local", text: $manualAddress)
                            .textFieldStyle(.roundedBorder)
                        Button("Connect") { Task { await model.connect(host: cleaned(manualAddress)) } }
                            .disabled(manualAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Pair…") { pairingManualHost = cleaned(manualAddress) }
                            .disabled(manualAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Button {
                        Task { await model.importCredentialsAndConnect(host: cleaned(manualAddress)) }
                    } label: {
                        Label("Import credentials from CLI / Sony app", systemImage: "square.and.arrow.down")
                    }
                    .disabled(manualAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .listStyle(.inset)

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { model.startDiscovery() }
        .sheet(item: $pairingDevice) { device in
            PairingView(host: device.host).environmentObject(model)
        }
        .sheet(isPresented: Binding(get: { pairingManualHost != nil }, set: { if !$0 { pairingManualHost = nil } })) {
            PairingView(host: pairingManualHost ?? "").environmentObject(model)
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.richtext")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Digital Paper").font(.largeTitle.bold())
            Text("Connect to your Sony Digital Paper or Fujitsu Quaderno")
                .foregroundStyle(.secondary)
            if case .connecting = model.connection {
                ProgressView().controlSize(.small).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func deviceRow(_ device: DiscoveredDevice) -> some View {
        HStack {
            Image(systemName: "doc.richtext.fill").foregroundStyle(.tint)
            VStack(alignment: .leading) {
                Text(device.displayName).fontWeight(.medium)
                Text("\(device.host)\(device.serialNumber.map { " · \($0)" } ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.hasCredentials(for: device) {
                Button("Connect") { Task { await model.connect(to: device) } }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Pair…") { pairingDevice = device }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 2)
    }

    private func cleaned(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
}
