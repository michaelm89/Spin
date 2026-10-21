import Foundation

enum RecordSize: String, CaseIterable, Identifiable {
    case small, medium, large, huge

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// Record diameter in points.
    var diameter: CGFloat {
        switch self {
        case .small: 220
        case .medium: 320
        case .large: 440
        case .huge: 600
        }
    }
}

enum RecordPosition: String, CaseIterable, Identifiable {
    case topLeft, topRight, bottomLeft, bottomRight, center

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        case .center: "Center"
        }
    }
}

enum DisplayStyle: String, CaseIterable, Identifiable {
    case room, floating

    var id: String { rawValue }
    var title: String { self == .room ? "Room" : "Floating Record" }
}

final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    @Published var style: DisplayStyle {
        didSet { defaults.set(style.rawValue, forKey: "style") }
    }

    @Published var size: RecordSize {
        didSet { defaults.set(size.rawValue, forKey: "size") }
    }

    @Published var position: RecordPosition {
        didSet { defaults.set(position.rawValue, forKey: "position") }
    }

    @Published var showTonearm: Bool {
        didSet { defaults.set(showTonearm, forKey: "showTonearm") }
    }

    private init() {
        style = DisplayStyle(rawValue: defaults.string(forKey: "style") ?? "") ?? .room
        size = RecordSize(rawValue: defaults.string(forKey: "size") ?? "") ?? .medium
        position = RecordPosition(rawValue: defaults.string(forKey: "position") ?? "") ?? .bottomRight
        showTonearm = defaults.object(forKey: "showTonearm") as? Bool ?? true
    }
}
