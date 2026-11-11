import SwiftUI
import NetlaneCore

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
            Image(systemName: model.view == .connected ? "lock.shield.fill" : model.view == .error || model.view == .killSwitch ? "exclamationmark.shield" : "lock.shield")
        }
    }
}

extension AppModel {
    static let shared = AppModel()
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
struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.statusTitle + (model.selectedServer.map { " · " + $0.name } ?? ""))
        Button(actionTitle) { model.toggle() }.disabled(model.view == .disconnecting)
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

    private var actionTitle: String {
        switch model.view {
        case .noProfile: return "Добавить сервер…"
        case .idle: return "Подключиться"
        case .error: return "Повторить"
        case .connecting: return "Отменить подключение"
        default: return "Отключиться"
        }
    }
}
