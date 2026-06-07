import Foundation
import Network

public struct DiscoveredDevice: Sendable, Hashable, Identifiable {
    public let serviceName: String
    public let host: String
    public let port: Int
    public var serialNumber: String?
    public var model: String?

    public var id: String { serviceName }
    public var displayName: String { model ?? serviceName }
}

/// Discovers Digital Paper devices via mDNS/Bonjour for both Sony and Fujitsu
/// service types, mirroring `LookUpDPT` in `dptrp1.py`.
///
/// Resolution: NWBrowser surfaces service instances; each is resolved to a
/// host/port via a short-lived NWConnection, then `/register/information` is
/// queried for the serial number and model.
public final class DeviceDiscovery: @unchecked Sendable {

    public static let serviceTypes = ["_digitalpaper._tcp", "_dp_fujitsu._tcp"]

    private var browsers: [NWBrowser] = []
    private let queue = DispatchQueue(label: "com.danielkao.digitalpaper.discovery")
    private var devices: [String: DiscoveredDevice] = [:]
    private var continuation: AsyncStream<[DiscoveredDevice]>.Continuation?

    public init() {}

    /// Start browsing. The returned stream yields the current device list on each change.
    public func devicesStream() -> AsyncStream<[DiscoveredDevice]> {
        AsyncStream { continuation in
            self.continuation = continuation
            self.startBrowsing()
            continuation.onTermination = { [weak self] _ in self?.stop() }
        }
    }

    private func startBrowsing() {
        for type in Self.serviceTypes {
            let params = NWParameters()
            params.includePeerToPeer = false
            let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: params)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                self?.handle(results: results)
            }
            browser.start(queue: queue)
            browsers.append(browser)
        }
    }

    private func handle(results: Set<NWBrowser.Result>) {
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            if devices[name] != nil { continue }
            resolve(endpoint: result.endpoint, serviceName: name, preferIPv4: true)
        }
    }

    /// Resolve a service to a host/port. A Digital Paper is often reachable on
    /// both Wi-Fi (routable IPv4) and USB (link-local IPv6) at the same time;
    /// we prefer IPv4 and fall back to IPv6 only if IPv4 resolution fails, so
    /// the address shown is stable and routable.
    private func resolve(endpoint: NWEndpoint, serviceName: String, preferIPv4: Bool) {
        let params = NWParameters.tcp
        if preferIPv4, let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: params)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let remote = connection.currentPath?.remoteEndpoint,
                   case let .hostPort(host, port) = remote {
                    let hostString = Self.string(from: host)
                    let device = DiscoveredDevice(serviceName: serviceName,
                                                  host: hostString,
                                                  port: Int(port.rawValue),
                                                  serialNumber: nil, model: nil)
                    self.queue.async { self.add(device) }
                }
                connection.cancel()
            case .failed:
                connection.cancel()
                if preferIPv4 {
                    // No IPv4 route (e.g. USB-only) — retry allowing IPv6.
                    self.resolve(endpoint: endpoint, serviceName: serviceName, preferIPv4: false)
                }
            case .cancelled:
                break
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func add(_ device: DiscoveredDevice) {
        devices[device.serviceName] = device
        emit()
        Task { await self.enrich(device) }
    }

    /// Query /register/information to fill in serial + model.
    private func enrich(_ device: DiscoveredDevice) async {
        guard let url = URL(string: "http://\(dpHostForURL(device.host)):\(device.port)/register/information") else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let info = try? JSONDecoder().decode(DeviceInfo.self, from: data) else { return }
        queue.async {
            guard var d = self.devices[device.serviceName] else { return }
            d.serialNumber = info.serialNumber
            d.model = info.displayModel
            self.devices[device.serviceName] = d
            self.emit()
        }
    }

    private func emit() {
        let list = devices.values.sorted { $0.serviceName < $1.serviceName }
        continuation?.yield(list)
    }

    public func stop() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        continuation?.finish()
        continuation = nil
    }

    private static func string(from host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let addr):
            // IPv4 never carries a zone; drop any trailing interface suffix.
            return String(describing: addr).components(separatedBy: "%").first ?? String(describing: addr)
        case .ipv6(let addr):
            // Keep the zone id (e.g. "%en5"): link-local addresses are
            // unroutable without it. URL bracketing adds it back as "%25en5".
            return String(describing: addr)
        case .name(let name, _):
            return name
        @unknown default:
            return String(describing: host)
        }
    }
}
