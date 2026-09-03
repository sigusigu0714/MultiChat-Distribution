import Foundation
import SwiftUI

struct ChannelConfig: Identifiable, Codable, Hashable {
    var id = UUID()
    var name = ""
    var platform: Platform = .twitch
    var channelIdentifier = ""
    var serverAccountID: String? = nil
    var serverWatchID: String? = nil
    var serverWatchPlatform: Platform? = nil
    var enabled = true
    var alertProvider: AlertProvider = .streamlabs

    var alertURLKey: String {
        "alert-url-\(id.uuidString)"
    }
}

enum Platform: String, Codable, CaseIterable, Identifiable {
    case youtube = "YouTube"
    case twitch = "Twitch"
    case kick = "KICK"

    var id: String {
        rawValue
    }

    var symbol: String {
        switch self {
        case .youtube:
            return "play.rectangle.fill"

        case .twitch:
            return "bubble.left.and.bubble.right.fill"

        case .kick:
            return "bolt.fill"
        }
    }

    var color: Color {
        switch self {
        case .youtube:
            return .red

        case .twitch:
            return .purple

        case .kick:
            return .green
        }
    }
}

enum AlertProvider: String, Codable, CaseIterable, Identifiable {
    case streamlabs = "Streamlabs"
    case streamelements = "StreamElements"

    var id: String {
        rawValue
    }
}

enum EventKind: String, Codable {
    case chat
    case bits
    case subscription
    case giftSubscription
    case donation
    case superChat
    case membership
    case follow
    case raid
    case system
}

struct ChatBadge: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var imageURL: String?

    init(
        id: String,
        name: String,
        imageURL: String? = nil
    ) {
        self.id = id
        self.name = name
        self.imageURL = imageURL
    }
}

struct ChatEmote: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var imageURL: String
    var start: Int?
    var end: Int?

    init(
        id: String,
        name: String,
        imageURL: String,
        start: Int? = nil,
        end: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.imageURL = imageURL
        self.start = start
        self.end = end
    }
}

struct UnifiedEvent: Identifiable, Codable, Hashable {
    var id: String

    var channelID: UUID?
    var platform: Platform
    var channelName: String

    var kind: EventKind

    var userName: String
    var userID: String?

    var message: String

    var amountText: String?
    var amountValue: Double?
    var currency: String?

    var userAvatarURL: String?

    var badges: [ChatBadge]
    var emotes: [ChatEmote]

    var translatedMessage: String?
    var detectedLanguage: String?

    var sourceMessageID: String?
    var source: String?

    var timestamp: Date

    var isAlert: Bool {
        kind != .chat &&
        kind != .system
    }

    var isPaidEvent: Bool {
        switch kind {
        case .bits,
             .subscription,
             .giftSubscription,
             .donation,
             .superChat,
             .membership:
            return true

        default:
            return false
        }
    }

    // MARK: - 通常生成用

    init(
        id: String,
        channelID: UUID? = nil,
        platform: Platform,
        channelName: String,
        kind: EventKind,
        userName: String,
        userID: String? = nil,
        message: String,
        amountText: String? = nil,
        amountValue: Double? = nil,
        currency: String? = nil,
        userAvatarURL: String? = nil,
        badges: [ChatBadge] = [],
        emotes: [ChatEmote] = [],
        translatedMessage: String? = nil,
        detectedLanguage: String? = nil,
        sourceMessageID: String? = nil,
        source: String? = nil,
        timestamp: Date
    ) {
        self.id = id
        self.channelID = channelID
        self.platform = platform
        self.channelName = channelName
        self.kind = kind
        self.userName = userName
        self.userID = userID
        self.message = message
        self.amountText = amountText
        self.amountValue = amountValue
        self.currency = currency
        self.userAvatarURL = userAvatarURL
        self.badges = badges
        self.emotes = emotes
        self.translatedMessage = translatedMessage
        self.detectedLanguage = detectedLanguage
        self.sourceMessageID = sourceMessageID
        self.source = source
        self.timestamp = timestamp
    }

    // MARK: - 古いJSON互換デコード

    enum CodingKeys: String, CodingKey {
        case id
        case channelID
        case platform
        case channelName
        case kind
        case userName
        case userID
        case message
        case amountText
        case amountValue
        case currency
        case userAvatarURL
        case badges
        case emotes
        case translatedMessage
        case detectedLanguage
        case sourceMessageID
        case source
        case timestamp
    }

    init(from decoder: Decoder) throws {
        let container =
            try decoder.container(
                keyedBy: CodingKeys.self
            )

        id =
            try container.decode(
                String.self,
                forKey: .id
            )

        channelID =
            try container.decodeIfPresent(
                UUID.self,
                forKey: .channelID
            )

        platform =
            try container.decode(
                Platform.self,
                forKey: .platform
            )

        channelName =
            try container.decode(
                String.self,
                forKey: .channelName
            )

        kind =
            try container.decode(
                EventKind.self,
                forKey: .kind
            )

        userName =
            try container.decode(
                String.self,
                forKey: .userName
            )

        userID =
            try container.decodeIfPresent(
                String.self,
                forKey: .userID
            )

        message =
            try container.decodeIfPresent(
                String.self,
                forKey: .message
            )
            ?? ""

        amountText =
            try container.decodeIfPresent(
                String.self,
                forKey: .amountText
            )

        amountValue =
            try container.decodeIfPresent(
                Double.self,
                forKey: .amountValue
            )

        currency =
            try container.decodeIfPresent(
                String.self,
                forKey: .currency
            )

        userAvatarURL =
            try container.decodeIfPresent(
                String.self,
                forKey: .userAvatarURL
            )

        badges =
            try container.decodeIfPresent(
                [ChatBadge].self,
                forKey: .badges
            )
            ?? []

        emotes =
            try container.decodeIfPresent(
                [ChatEmote].self,
                forKey: .emotes
            )
            ?? []

        translatedMessage =
            try container.decodeIfPresent(
                String.self,
                forKey: .translatedMessage
            )

        detectedLanguage =
            try container.decodeIfPresent(
                String.self,
                forKey: .detectedLanguage
            )

        sourceMessageID =
            try container.decodeIfPresent(
                String.self,
                forKey: .sourceMessageID
            )

        source =
            try container.decodeIfPresent(
                String.self,
                forKey: .source
            )

        timestamp =
            try container.decode(
                Date.self,
                forKey: .timestamp
            )
    }
}