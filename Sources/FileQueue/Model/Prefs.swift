import Foundation

enum TransferOperation: String, Codable, CaseIterable, Identifiable {
    case copy, move

    var id: String { rawValue }
    var verb: String { self == .copy ? "copy" : "move" }
    var title: String { self == .copy ? "Copy" : "Move" }
    var symbol: String { self == .copy ? "doc.on.doc.fill" : "arrow.right.doc.on.clipboard" }
}

enum TransferEngineKind: String, Codable, CaseIterable, Identifiable {
    case builtIn, finder
    var id: String { rawValue }
}

enum ConflictPolicy: String, Codable, CaseIterable, Identifiable {
    case keepBoth, replace, skip
    var id: String { rawValue }

    var title: String {
        switch self {
        case .keepBoth: "Keep both (rename new item)"
        case .replace: "Replace existing item"
        case .skip: "Skip the item"
        }
    }
}

/// UserDefaults keys shared between `@AppStorage` in views and the queue engine.
enum PrefKey {
    static let engine = "engine"
    static let conflict = "conflictPolicy"
    static let maxConcurrent = "maxConcurrent"
    static let verify = "verifyAfterCopy"
    static let trashMovedSources = "trashMovedSources"
    static let notify = "notifications"
    static let preventSleep = "preventSleep"
    static let defaultOperation = "defaultOperation"
    static let destination = "destination"
    static let recents = "recentDestinations"
    static let favorites = "favoriteDestinations"
}

enum Prefs {
    static var d: UserDefaults { .standard }

    static func register() {
        d.register(defaults: [
            PrefKey.engine: TransferEngineKind.builtIn.rawValue,
            PrefKey.conflict: ConflictPolicy.keepBoth.rawValue,
            PrefKey.maxConcurrent: 1,
            PrefKey.verify: true,
            PrefKey.trashMovedSources: false,
            PrefKey.notify: true,
            PrefKey.preventSleep: true,
            PrefKey.defaultOperation: TransferOperation.copy.rawValue,
        ])
    }

    static var engine: TransferEngineKind {
        TransferEngineKind(rawValue: d.string(forKey: PrefKey.engine) ?? "") ?? .builtIn
    }
    static var conflict: ConflictPolicy {
        ConflictPolicy(rawValue: d.string(forKey: PrefKey.conflict) ?? "") ?? .keepBoth
    }
    static var maxConcurrent: Int { min(max(d.integer(forKey: PrefKey.maxConcurrent), 1), 8) }
    static var verify: Bool { d.bool(forKey: PrefKey.verify) }
    static var trashMovedSources: Bool { d.bool(forKey: PrefKey.trashMovedSources) }
    static var notify: Bool { d.bool(forKey: PrefKey.notify) }
    static var preventSleep: Bool { d.bool(forKey: PrefKey.preventSleep) }
    static var defaultOperation: TransferOperation {
        TransferOperation(rawValue: d.string(forKey: PrefKey.defaultOperation) ?? "") ?? .copy
    }
}
