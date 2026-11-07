import Foundation

// MARK: - RecapWindow

enum RecapWindow: Equatable, Sendable {
    case minutes(Int)
    case sinceStart

    var label: String {
        switch self {
        case .minutes(let n): return "Last \(n) min"
        case .sinceStart: return "Since start"
        }
    }

    var shortLabel: String {
        switch self {
        case .minutes(let n): return "\(n) min"
        case .sinceStart: return "Since start"
        }
    }
}

// MARK: - RecapEntry

struct RecapEntry: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let createdAt: Date
    let windowLabel: String
    let coversFrom: Date
    let coversTo: Date
    let utteranceCount: Int
    let truncated: Bool
    let text: String
}

// MARK: - SidecastHistoryEntry

enum SidecastHistoryEntry: Identifiable, Codable, Sendable, Equatable {
    case message(SidecastMessage)
    case recap(RecapEntry)

    var id: UUID {
        switch self {
        case .message(let m): return m.id
        case .recap(let r): return r.id
        }
    }

    var timestamp: Date {
        switch self {
        case .message(let m): return m.timestamp
        case .recap(let r): return r.createdAt
        }
    }

    var text: String {
        switch self {
        case .message(let m): return m.text
        case .recap(let r): return r.text
        }
    }

    /// Persona name for messages; windowLabel for recaps.
    var title: String {
        switch self {
        case .message(let m): return m.personaName
        case .recap(let r): return r.windowLabel
        }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case type, payload
    }

    private enum EntryType: String, Codable {
        case message, recap
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(EntryType.self, forKey: .type)
        switch type {
        case .message:
            self = .message(try container.decode(SidecastMessage.self, forKey: .payload))
        case .recap:
            self = .recap(try container.decode(RecapEntry.self, forKey: .payload))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .message(let m):
            try container.encode(EntryType.message, forKey: .type)
            try container.encode(m, forKey: .payload)
        case .recap(let r):
            try container.encode(EntryType.recap, forKey: .type)
            try container.encode(r, forKey: .payload)
        }
    }
}
