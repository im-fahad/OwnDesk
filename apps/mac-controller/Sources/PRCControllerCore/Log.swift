import os

enum Log {
    static let app = Logger(subsystem: "prc.controller", category: "app")
    static let signaling = Logger(subsystem: "prc.controller", category: "signaling")
    static let session = Logger(subsystem: "prc.controller", category: "session")
    static let media = Logger(subsystem: "prc.controller", category: "media")
}
