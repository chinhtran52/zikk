import Foundation

public enum SidebarSection: String, CaseIterable, Identifiable, Sendable {
    case collections, environments, specs, mocks, datasets, history

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .collections: L("Collections")
        case .environments: L("Environments")
        case .specs: L("APIs")
        case .mocks: L("Mock Servers")
        case .datasets: L("Datasets")
        case .history: L("History")
        }
    }

    public var systemImage: String {
        switch self {
        case .collections: "folder"
        case .environments: "square.stack.3d.up"
        case .specs: "doc.text"
        case .mocks: "server.rack"
        case .datasets: "tablecells"
        case .history: "clock.arrow.circlepath"
        }
    }
}
