import SwiftUI
import DigitalPaperKit

enum AppSection: String, CaseIterable, Identifiable {
    case documents = "Documents"
    case wifi = "Wi-Fi"
    case system = "System"
    case templates = "Templates"
    case sync = "Sync"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .documents: return "folder"
        case .wifi: return "wifi"
        case .system: return "gearshape"
        case .templates: return "doc.on.doc"
        case .sync: return "arrow.triangle.2.circlepath"
        }
    }
}

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: AppSection? = .documents

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                DeviceCard()
                Divider()
                List(AppSection.allCases, selection: $selection) { section in
                    Label(section.rawValue, systemImage: section.icon).tag(section)
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 220)
        } detail: {
            switch selection ?? AppSection.documents {
            case .documents: DocumentsView()
            case .wifi: WifiView()
            case .system: SystemView()
            case .templates: TemplatesView()
            case .sync: SyncView()
            }
        }
    }
}

struct DeviceCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "doc.richtext.fill").font(.title2).foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    if case let .connected(info) = model.connection {
                        Text(info.displayModel).fontWeight(.semibold)
                        Text(info.serialNumber).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            if let battery = model.battery, let level = battery.level {
                ProgressView(value: Double(level), total: 100) {
                    Label("Battery \(level)%", systemImage: batteryIcon(level))
                        .font(.caption)
                }
                .tint(level < 20 ? .red : .green)
            }

            if let storage = model.storage, let cap = storage.capacityBytes, let avail = storage.availableBytes, cap > 0 {
                let used = cap - avail
                ProgressView(value: Double(used), total: Double(cap)) {
                    Text("\(byteString(avail)) free of \(byteString(cap))").font(.caption)
                }
            }

            if let fw = model.firmware, !fw.isEmpty {
                Text("Firmware \(fw)").font(.caption2).foregroundStyle(.secondary)
            }

            Button {
                model.disconnect()
            } label: {
                Label("Disconnect", systemImage: "eject").font(.caption)
            }
            .buttonStyle(.borderless)
            .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await model.refreshStatus() }
    }

    private func batteryIcon(_ level: Int) -> String {
        switch level {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }
}

func byteString(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
