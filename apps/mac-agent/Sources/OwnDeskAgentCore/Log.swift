import os

/// Loggers per subsystem. Rule 4 of the spec: never log keys, pairing codes, input contents, or frames.
/// Device ids, session ids, message types, and connection paths are fine.
enum Log {
    static let agent = Logger(subsystem: "owndesk.agent", category: "agent")
    static let signaling = Logger(subsystem: "owndesk.agent", category: "signaling")
    static let session = Logger(subsystem: "owndesk.agent", category: "session")
    static let media = Logger(subsystem: "owndesk.agent", category: "media")
    static let input = Logger(subsystem: "owndesk.agent", category: "input")
}
