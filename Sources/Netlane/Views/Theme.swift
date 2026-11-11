import SwiftUI
import NetlaneCore

/// The one palette of the client, the same as on Windows. Accent is for the main action and active
/// elements; `protected` only for «connected».
enum Theme {
    static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
    static let ground = rgb(0x101624)
    static let card = rgb(0x131B2B)
    static let raised = rgb(0x1A2437)
    static let line = rgb(0x273149)
    static let lineStrong = rgb(0x36415A)
    static let ink = rgb(0xF1F3FB)
    static let muted = rgb(0xABB6CC)
    static let faint = rgb(0x8E9AB1)
    static let accent = rgb(0x22D3E6)
    static let accentInk = rgb(0x06222A)
    static let protected = rgb(0x62DBB0)
    static let warning = rgb(0xFFBF87)
    static let upload = rgb(0xFFBF87)
    static let danger = rgb(0xF2837A)
    static let stop = rgb(0xC43B49)
    static let selection = accent.opacity(0.12)

    static func dot(_ view: ConnectionView) -> Color {
        switch view {
        case .connected: return protected
        case .connecting: return accent
        case .reconnecting: return warning
        case .killSwitch, .error, .disconnecting: return danger
        case .noProfile, .idle: return faint
        }
    }
    static func level(_ level: Account.Level) -> Color {
        switch level {
        case .normal: return faint
        case .warning: return warning
        case .danger: return danger
        }
    }
}

/// The wide button of the main action: accent to connect, red to disconnect.
struct PrimaryButtonStyle: ButtonStyle {
    var fill: Color = Theme.accent
    var ink: Color = Theme.accentInk
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(ink)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(RoundedRectangle(cornerRadius: 10).fill(fill.opacity(!enabled ? 0.35 : configuration.isPressed ? 0.8 : 1)))
            .contentShape(Rectangle())
    }
}

/// A quiet button with a border: secondary actions.
struct QuietButtonStyle: ButtonStyle {
    var tint: Color = Theme.ink
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundColor(tint.opacity(enabled ? 1 : 0.4))
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(configuration.isPressed ? Theme.lineStrong : Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
            .contentShape(Rectangle())
    }
}

/// Text that acts as a link (accent colour, hand cursor).
struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12)).foregroundColor(Theme.accent.opacity(configuration.isPressed ? 0.6 : 1)).contentShape(Rectangle())
    }
}

/// Small caps heading above a block, with a hairline under it.
struct SectionTitle: View {
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.system(size: 11)).foregroundColor(Theme.faint)
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }
}

/// Page heading with an optional explanation under it.
struct PageHeader: View {
    let title: String
    var subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 20, weight: .semibold)).foregroundColor(Theme.ink)
            if let subtitle = subtitle { Text(subtitle).font(.system(size: 12)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// A switch row of the settings: title, explanation, toggle.
struct ToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13)).foregroundColor(Theme.ink)
                Text(detail).font(.system(size: 11)).foregroundColor(Theme.faint).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().tint(Theme.accent)
        }
        .padding(.vertical, 8)
    }
}

/// HTTP/2 | HTTP/3 style switch: a few short options in one rounded frame.
struct Choice: Identifiable {
    let value: String
    let title: String
    var id: String { value }
    init(_ value: String, _ title: String) { self.value = value; self.title = title }
}

struct SegmentedChoice: View {
    let options: [Choice]
    let selected: String
    let pick: (String) -> Void
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                Button(action: { pick(option.value) }) {
                    Text(option.title)
                        .font(.system(size: 12, weight: option.value == selected ? .semibold : .regular))
                        .foregroundColor(option.value == selected ? Theme.ink : Theme.muted)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .background(RoundedRectangle(cornerRadius: 7).fill(option.value == selected ? Theme.raised : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(option.value == selected ? Theme.lineStrong : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
    }
}

/// One lane of the speed graph: the last minute, scaled to its own peak.
struct SpeedLane: View {
    let title: String
    let arrow: String
    let color: Color
    let values: [Double]
    let current: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 11)).foregroundColor(Theme.faint)
                Spacer()
                Text(arrow + " " + SessionStats.rate(current)).font(.system(size: 11)).foregroundColor(color).monospacedDigit()
            }
            GeometryReader { geometry in
                let peak = max(values.max() ?? 0, 1024)
                Path { path in
                    guard values.count > 1 else { return }
                    let step = geometry.size.width / 59
                    let offset = Double(60 - values.count) * step
                    for (i, value) in values.enumerated() {
                        let point = CGPoint(x: offset + Double(i) * step, y: geometry.size.height - 1 - (value / peak) * (geometry.size.height - 3))
                        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                Rectangle().fill(Theme.line).frame(height: 1).offset(y: geometry.size.height - 1)
            }
            .frame(height: 26)
            .help("Пик за минуту: " + SessionStats.rate(values.max() ?? 0))
        }
    }
}

/// One line of a drop-down menu.
enum DropdownItem {
    case item(String, checked: Bool = false, action: () -> Void)
    case separator
}

/// A bordered drop-down: the whole frame (text, arrow, padding) is one button, and the menu opens right
/// under it. SwiftUI's Menu only reacts to clicks on its own text and puts any image before the text.
struct DropdownButton: View {
    let title: String
    let items: () -> [DropdownItem]
    @State private var frame: CGRect = .zero

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 12)).foregroundColor(Theme.ink).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundColor(Theme.faint)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .background(GeometryReader { geometry in
            Color.clear
                .onAppear { frame = geometry.frame(in: .global) }
                .onChange(of: geometry.frame(in: .global)) { frame = $0 }
        })
    }

    private func open() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.appearance = NSAppearance(named: .darkAqua)
        var targets: [MenuTarget] = []
        for entry in items() {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .item(let text, let checked, let action):
                let target = MenuTarget(action)
                targets.append(target)
                let item = NSMenuItem(title: text, action: #selector(MenuTarget.run), keyEquivalent: "")
                item.target = target
                item.state = checked ? .on : .off
                menu.addItem(item)
            }
        }
        guard let view = NSApp.keyWindow?.contentView ?? NSApp.mainWindow?.contentView else { return }
        // SwiftUI's global frame counts from the window's top left; AppKit may count from the bottom.
        let y = view.isFlipped ? frame.maxY + 4 : view.bounds.height - frame.maxY - 4
        menu.minimumWidth = frame.width
        menu.popUp(positioning: nil, at: NSPoint(x: frame.minX, y: y), in: view)
        withExtendedLifetime(targets) {}
    }
}

/// Keeps a closure alive as the target of an NSMenuItem.
final class MenuTarget: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}

extension View {
    /// The hand cursor over clickable rows and links.
    func handCursor() -> some View {
        onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
    }
}
