import SwiftUI

/// A dark editor-style palette. Fixed rather than adaptive: the window is mostly a video surface,
/// and a light chrome around a dark desktop stream reads badly.
enum Theme {
    static let header = Color(hex: 0x1B1B1B)
    static let sidebar = Color(hex: 0x181818)
    static let content = Color(hex: 0x1F1F1F)
    static let panel = Color(hex: 0x1A1A1A)
    static let status = Color(hex: 0x161616)
    static let border = Color(hex: 0x2E2E2E)
    static let hover = Color(hex: 0x2A2D2E)
    static let selection = Color(hex: 0x04395E)

    static let text = Color(hex: 0xCCCCCC)
    static let textDim = Color(hex: 0x8B8B8B)
    static let textFaint = Color(hex: 0x6A6A6A)

    static let accent = Color(hex: 0x4D8EF7)
    static let online = Color(hex: 0x3FB950)
    static let warn = Color(hex: 0xD29922)
    static let danger = Color(hex: 0xF85149)

    // Sizes follow an editor's chrome: 13 for primary UI, 12 for secondary, 11 for status and
    // section headings. Smaller than this reads as cramped on a Retina display.
    static let ui = Font.system(size: 13)
    static let uiMedium = Font.system(size: 13, weight: .medium)
    static let uiSecondary = Font.system(size: 12)
    static let uiSmall = Font.system(size: 11)
    static let section = Font.system(size: 11, weight: .semibold)
    static let mono = Font.system(size: 12, design: .monospaced)
    static let monoSmall = Font.system(size: 11, design: .monospaced)
    static let monoLarge = Font.system(size: 15, design: .monospaced)

    /// Height of the unified title bar. Room for the traffic lights plus a control.
    static let headerHeight: CGFloat = 40
    /// Left inset that keeps content clear of the traffic lights.
    static let trafficLightInset: CGFloat = 78
}

/// Makes the window's title bar part of the content, so the header is the title bar rather than a
/// second row beneath an empty one.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.backgroundColor = NSColor(Theme.content)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// A flat square icon button, the kind that lines the edges of an editor window.
struct IconButton: View {
    let systemName: String
    let help: String
    var isOn: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(isOn ? Theme.text : Theme.textDim)
                .frame(width: 28, height: 26)
                .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
