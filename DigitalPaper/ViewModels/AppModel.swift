import Foundation
import SwiftUI
import DigitalPaperKit

@MainActor
final class AppModel: ObservableObject {

    enum Connection: Equatable {
        case disconnected
        case connecting
        case connected(DeviceInfo)
    }

    @Published var discovered: [DiscoveredDevice] = []
    @Published var connection: Connection = .disconnected
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    @Published var battery: BatteryInfo?
    @Published var storage: StorageInfo?
    @Published var firmware: String?

    private(set) var client: DigitalPaperClient?
    private(set) var currentSerial: String?
    private var discovery: DeviceDiscovery?
    private var discoveryTask: Task<Void, Never>?

    var isConnected: Bool { if case .connected = connection { return true }; return false }

    // MARK: Discovery

    func startDiscovery() {
        guard discovery == nil else { return }
        let discovery = DeviceDiscovery()
        self.discovery = discovery
        discoveryTask = Task {
            for await devices in discovery.devicesStream() {
                self.discovered = devices
            }
        }
    }

    func stopDiscovery() {
        discoveryTask?.cancel()
        discovery?.stop()
        discovery = nil
        discoveryTask = nil
    }

    /// True if we already hold credentials for this device's serial.
    func hasCredentials(for device: DiscoveredDevice) -> Bool {
        guard let serial = device.serialNumber else { return false }
        return CredentialStore.load(serial: serial) != nil
    }

    // MARK: Connect (already paired)

    func connect(host: String) async {
        connection = .connecting
        errorMessage = nil
        do {
            let client = DigitalPaperClient(host: host)
            let info = try await client.fetchDeviceInfo()
            guard let creds = CredentialStore.load(serial: info.serialNumber) else {
                connection = .disconnected
                errorMessage = "No saved credentials for \(info.serialNumber). Pair the device first."
                return
            }
            try await client.authenticate(clientID: creds.clientID, privateKeyPEM: creds.privateKeyPEM)
            try await client.ping()
            self.client = client
            self.currentSerial = info.serialNumber
            self.connection = .connected(info)
            await refreshStatus()
        } catch {
            connection = .disconnected
            errorMessage = error.localizedDescription
        }
    }

    func connect(to device: DiscoveredDevice) async {
        await connect(host: device.host)
    }

    /// Import credentials created by the CLI / Sony app, then connect.
    func importCredentialsAndConnect(host: String) async {
        guard let creds = CredentialStore.importExisting() else {
            errorMessage = "No existing credentials found in ~/.config/dpt or the Sony app folders."
            return
        }
        connection = .connecting
        do {
            let client = DigitalPaperClient(host: host)
            let info = try await client.fetchDeviceInfo()
            try CredentialStore.save(creds, serial: info.serialNumber)
            try await client.authenticate(clientID: creds.clientID, privateKeyPEM: creds.privateKeyPEM)
            try await client.ping()
            self.client = client
            self.currentSerial = info.serialNumber
            self.connection = .connected(info)
            await refreshStatus()
        } catch {
            connection = .disconnected
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() {
        client = nil
        currentSerial = nil
        connection = .disconnected
        battery = nil
        storage = nil
        firmware = nil
    }

    // MARK: Status

    func refreshStatus() async {
        guard let client else { return }
        async let battery = try? client.battery()
        async let storage = try? client.storage()
        async let firmware = try? client.firmwareVersion()
        self.battery = await battery
        self.storage = await storage
        self.firmware = await firmware
    }

    // MARK: Convenience

    func finishPairing(host: String, serial: String, info: DeviceInfo, client: DigitalPaperClient) async {
        self.client = client
        self.currentSerial = serial
        self.connection = .connected(info)
        await refreshStatus()
    }
}
