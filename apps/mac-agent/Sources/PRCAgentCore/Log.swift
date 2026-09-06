import os

/// Loggers per subsystem. Rule 4 of the spec: never log keys, pairing codes, input contents, or frames.
/// Device ids, session ids, message types, and connection paths are fine.
enum Log {
    static let agent = Logger(subsystem: "prc.agent", category: "agent")
    static let signaling = Logger(subsystem: "prc.agent", category: "signaling")
    static let session = Logger(subsystem: "prc.agent", category: "session")
    static let media = Logger(subsystem: "prc.agent", category: "media")
    static let input = Logger(subsystem: "prc.agent", category: "input")
}
