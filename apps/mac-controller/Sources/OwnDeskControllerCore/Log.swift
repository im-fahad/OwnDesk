import os

enum Log {
    static let app = Logger(subsystem: "owndesk.controller", category: "app")
    static let signaling = Logger(subsystem: "owndesk.controller", category: "signaling")
    static let session = Logger(subsystem: "owndesk.controller", category: "session")
    static let media = Logger(subsystem: "owndesk.controller", category: "media")
}
