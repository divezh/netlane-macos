import AppKit
import SwiftUI
import NetlaneCore

/// `Netlane --render <folder>`: draws the window with made-up data into PNG files for the README
/// (home, rules) and the user guide (empty, add). No disk state, no network, no VPN.
enum Render {
    @MainActor
    static func demoState() throws -> ClientState {
        var state = ClientState()
        let sub = try state.addSubscription("https://panel.example.com/sub/demo-token")
        var feed = SubscriptionFeed()
        feed.name = "Netlane"
        feed.accountStatus = "active"
        feed.expiresAt = Account.formatDate(Date().addingTimeInterval(24 * 86400))
        feed.quotaBytes = 50 << 30
        feed.quotaUsedBytes = 13_314_398_617
        for (i, entry) in [("NL", "Амстердам", "http3"), ("DE", "Франкфурт", "http3"), ("FI", "Хельсинки", "http2"), ("US", "Нью-Йорк", "http2")].enumerated() {
            var server = Server()
            server.name = entry.1; server.country = entry.0
            server.hostname = "vpn\(i + 1).example.com"; server.address = server.hostname + ":443"
            server.username = "demo"; server.password = "demo-password-123"; server.transport = entry.2
            server.remoteId = "node\(i + 1)"
            feed.servers.append(server)
        }
        var operators = RuleSet()
        operators.remoteId = "operators"; operators.name = "Операторы"
        operators.routing = Routing(mode: "selective", destinations: ["uiscom.ru", "*.jivosite.com"], applications: [
            AppRule(name: "UIS Operator Workplace.exe", action: "vpn"), AppRule(name: "Jivo.exe", action: "vpn"),
            AppRule(name: "communicator_Exolve.exe", action: "vpn")])
        feed.ruleSets = [operators]
        feed.settingsRevision = 1
        try state.applyFeed(sub.id, feed, connectedServerId: nil)
        state.selectedServerId = state.servers.first?.id
        if let set = state.ruleSets.first(where: { $0.managed }) { state.selectedRuleSetId = set.id }
        try state.updateServer(state.servers[0].id) { $0.chosenTransport = "auto"; $0.autoTransport = "http3" }
        return state
    }

    /// Draws one view off screen into folder/name.png.
    @MainActor
    static func snapshot<V: View>(_ view: V, size: NSSize, name: String, folder: String) throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        // Let SwiftUI lay out and draw before the picture is taken.
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw FormatError("no bitmap") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw FormatError("no png") }
        let file = (folder as NSString).appendingPathComponent(name + ".png")
        try png.write(to: URL(fileURLWithPath: file))
        print("rendered " + file + " \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
        window.orderOut(nil)
    }

    @MainActor
    static func run(to folder: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.appearance = NSAppearance(named: .darkAqua)
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let window = NSSize(width: 920, height: 560)
            let model = AppModel(demo: try demoState())
            model.showDemoSession()
            for (name, page) in [("home", Page.home), ("rules", Page.rules)] {
                model.page = page
                try snapshot(MainWindow().environmentObject(model), size: window, name: name, folder: folder)
            }
            // For the user guide: the first start without servers and the «Добавить» sheet.
            let empty = AppModel(demo: ClientState())
            try snapshot(MainWindow().environmentObject(empty), size: window, name: "empty", folder: folder)
            try snapshot(AddSheet(text: "https://vpn.example.com/sub/Xk3pQ9vL2mR8tY4w").environmentObject(empty), size: NSSize(width: 520, height: 230), name: "add", folder: folder)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data(("render failed: \(error)\n").utf8))
            exit(1)
        }
    }
}
