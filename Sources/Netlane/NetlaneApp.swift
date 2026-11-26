import AppKit
import Combine
import SwiftUI
import NetlaneCore

@available(macOS 13.0, *)
struct NetlaneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Netlane", id: "main") {
            MainWindow().environmentObject(model)
        }
        .defaultSize(width: 920, height: 560)
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .newItem) {} }

        MenuBarExtra {
            MenuBarContent().environmentObject(model)
        } label: {
            Image(systemName: model.menuBarSymbol)
        }
    }
}

extension AppModel {
    static let shared = AppModel()

    var menuBarSymbol: String {
        switch view {
        case .connected: return "lock.shield.fill"
        case .error, .killSwitch: return "exclamationmark.shield"
        default: return "lock.shield"
        }
    }

    var menuBarActionTitle: String {
        switch view {
        case .noProfile: return "Добавить сервер…"
        case .idle: return "Подключиться"
        case .error: return "Повторить"
        case .connecting: return "Отменить подключение"
        default: return "Отключиться"
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Started at login («--hidden»): only the menu bar icon, no window.
        if AppModel.shared.startHidden && AppModel.shared.state.keepInMenuBar {
            DispatchQueue.main.async { NSApp.windows.filter { $0.canBecomeMain }.forEach { $0.close() } }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !AppModel.shared.state.keepInMenuBar
    }
}

/// The menu of the menu bar icon: state, the main action, locations, the window, quitting.
@available(macOS 13.0, *)
struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.statusTitle + (model.selectedServer.map { " · " + $0.name } ?? ""))
        Button(model.menuBarActionTitle) { model.toggle() }.disabled(model.view == .disconnecting)
        if !model.state.servers.isEmpty {
            Divider()
            ForEach(model.state.servers) { server in
                Button(action: { model.select(server: server.id) }) {
                    let title = (ServerName.flag(server.country).map { $0 + " " } ?? "") + server.name
                    if server.id == model.state.selectedServerId { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
        }
        Divider()
        Button("Открыть Netlane") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Выход") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

}

/// AppKit owns the single window and menu bar item on Monterey.
@MainActor
final class MontereyAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = AppModel.shared
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var statusObserver: AnyCancellable?

    static func run() {
        let app = NSApplication.shared
        let delegate = MontereyAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(menuItem("Выход из Netlane", #selector(quit), key: "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateStatusIcon()
        statusObserver = model.$view.dropFirst().sink { [weak self] _ in
            // @Published emits before the stored state changes.
            DispatchQueue.main.async { self?.updateStatusIcon() }
        }
        if !model.startHidden || !model.state.keepInMenuBar { openWindow() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !model.state.keepInMenuBar
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { openWindow() }
        return true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: model.statusTitle + (model.selectedServer.map { " · " + $0.name } ?? ""),
                                action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        let action = menuItem(model.menuBarActionTitle, #selector(toggle))
        action.isEnabled = model.view != .disconnecting
        menu.addItem(action)
        if !model.state.servers.isEmpty {
            menu.addItem(.separator())
            for server in model.state.servers {
                let title = (ServerName.flag(server.country).map { $0 + " " } ?? "") + server.name
                let item = menuItem(title, #selector(selectServer(_:)))
                item.representedObject = server.id
                item.state = server.id == model.state.selectedServerId ? .on : .off
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        menu.addItem(menuItem("Открыть Netlane", #selector(openWindow)))
        menu.addItem(menuItem("Выход", #selector(quit)))
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func updateStatusIcon() {
        statusItem?.button?.image = NSImage(systemSymbolName: model.menuBarSymbol, accessibilityDescription: "Netlane")
    }

    @objc private func toggle() {
        if model.view == .noProfile { openWindow() }
        model.toggle()
    }

    @objc private func selectServer(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { model.select(server: id) }
    }

    @objc private func openWindow() {
        if window == nil {
            let primary = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 560),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                   backing: .buffered, defer: false)
            primary.title = "Netlane"
            primary.isReleasedWhenClosed = false
            primary.contentView = NSHostingView(rootView: MainWindow().environmentObject(model))
            primary.contentMinSize = NSSize(width: 860, height: 520)
            primary.center()
            window = primary
        }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        }

    @objc private func quit() { NSApp.terminate(nil) }
    }
}
