import AppKit
import Foundation

/// This Mac's clipboard, as clipboard sync sees it: plain text in, plain text out, and a counter that
/// moves whenever anything on the Mac copies. Behind a protocol so that tests, and the headless agent
/// under test, never touch the real one.
public protocol ClipboardBridge: AnyObject, Sendable {
    /// Moves on every change, whoever made it.
    var changeCount: Int { get }
    /// The text on the clipboard now, if there is any.
    func readText() -> String?
    /// Puts text on the clipboard and returns the counter it left, so the change is known as ours.
    @discardableResult
    func write(_ text: String) -> Int
}

/// NSPasteboard.general. Its methods are safe from any thread.
public final class SystemClipboard: ClipboardBridge, @unchecked Sendable {
    public init() {}

    public var changeCount: Int { NSPasteboard.general.changeCount }

    public func readText() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    public func write(_ text: String) -> Int {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        return board.changeCount
    }
}
