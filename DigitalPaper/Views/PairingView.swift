import SwiftUI
import DigitalPaperKit

@MainActor
final class PairingModel: ObservableObject {
    enum Phase: Equatable {
        case idle, starting, awaitingPIN, completing, done, failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var pin: String = ""

    private var client: DigitalPaperClient?
    private var registration: Registration?
    private var deviceInfo: DeviceInfo?

    let host: String
    init(host: String) { self.host = host }

    func begin() async {
        phase = .starting
        do {
            let client = DigitalPaperClient(host: host)
            let info = try await client.fetchDeviceInfo()
            let registration = Registration(client: client)
            try await registration.begin()
            self.client = client
            self.registration = registration
            self.deviceInfo = info
            phase = .awaitingPIN
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func complete(app: AppModel) async {
        guard let registration, let client, let info = deviceInfo else { return }
        phase = .completing
        do {
            let creds = try await registration.complete(pin: pin.trimmingCharacters(in: .whitespaces))
            try CredentialStore.save(creds, serial: info.serialNumber)
            try await client.authenticate(clientID: creds.clientID, privateKeyPEM: creds.privateKeyPEM)
            try await client.ping()
            await app.finishPairing(host: host, serial: info.serialNumber, info: info, client: client)
            phase = .done
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

struct PairingView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: PairingModel

    init(host: String) {
        _model = StateObject(wrappedValue: PairingModel(host: host))
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair Digital Paper").font(.title2.bold())
            Text(model.host).font(.callout).foregroundStyle(.secondary)

            switch model.phase {
            case .idle, .starting:
                VStack(spacing: 10) {
                    ProgressView()
                    Text(model.phase == .starting ? "Contacting device…" : "Preparing…")
                        .foregroundStyle(.secondary)
                }
                .frame(height: 120)

            case .awaitingPIN:
                VStack(spacing: 12) {
                    Label("A PIN is now shown on the device screen.", systemImage: "lock.shield")
                        .foregroundStyle(.secondary)
                    TextField("PIN", text: $model.pin)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.title2, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .frame(width: 160)
                        .onSubmit { Task { await model.complete(app: app) } }
                    Button("Pair") { Task { await model.complete(app: app) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.pin.trimmingCharacters(in: .whitespaces).count < 4)
                }
                .frame(height: 120)

            case .completing:
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Registering…").foregroundStyle(.secondary)
                }
                .frame(height: 120)

            case .done:
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(.green)
                    Text("Paired successfully").fontWeight(.medium)
                }
                .frame(height: 120)
                .task { try? await Task.sleep(nanoseconds: 700_000_000); dismiss() }

            case .failed(let message):
                VStack(spacing: 10) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 40)).foregroundStyle(.red)
                    Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Button("Try Again") { Task { await model.begin() } }
                }
                .frame(height: 120)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
            }
        }
        .padding(24)
        .frame(width: 420)
        .task { if model.phase == .idle { await model.begin() } }
    }
}
