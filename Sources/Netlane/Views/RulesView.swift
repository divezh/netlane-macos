import SwiftUI
import UniformTypeIdentifiers
import NetlaneCore

/// «Правила»: the list of rule sets on the left, the opened set on the right.
struct RulesView: View {
    @EnvironmentObject var model: AppModel

    private var opened: RuleSet? {
        model.state.ruleSets.first { $0.id == model.editedRuleSetId } ?? model.state.ruleSets.first { $0.id == model.state.selectedRuleSetId }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: "Правила", subtitle: "Набор правил решает, какие сайты идут через VPN. Набор для подключения выбирается на главной.")
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    ScrollView {
                        VStack(spacing: 2) { ForEach(model.state.ruleSets) { set in setRow(set) } }
                    }
                    Button(action: addSet) { Label("Новый набор", systemImage: "plus") }
                        .buttonStyle(QuietButtonStyle()).padding(.top, 8)
                        .disabled(model.state.ruleSets.count >= ClientState.maxRuleSets)
                }
                .frame(width: 210)
                if let set = opened {
                    // A new identity per set: the editor's draft is rebuilt when another set is opened.
                    RuleSetEditor(ruleSet: set).id(set.id)
                }
            }
        }
        .padding(24)
    }

    private func setRow(_ set: RuleSet) -> some View {
        let isOpen = set.id == opened?.id
        return Button(action: { model.editedRuleSetId = set.id }) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(set.name).font(.system(size: 13, weight: isOpen ? .semibold : .regular)).foregroundColor(Theme.ink).lineLimit(1)
                    if set.id == model.state.selectedRuleSetId { Circle().fill(Theme.accent).frame(width: 5, height: 5).help("Выбран для подключения") }
                }
                Text(set.managed ? "от администратора · " + set.routing.summary : set.routing.summary).font(.system(size: 11)).foregroundColor(Theme.faint).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(isOpen ? Theme.selection : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func addSet() {
        var created: RuleSet?
        let name = model.state.freeRuleSetName("Мои правила")
        if model.change({ created = try $0.addRuleSet(name, Routing(mode: "selective", destinations: [])) }) { model.editedRuleSetId = created?.id }
    }
}

/// One ruleSet: name, mode and the addresses, one per line. Built-in and administrator sets are read-only.
struct RuleSetEditor: View {
    @EnvironmentObject var model: AppModel
    let ruleSet: RuleSet
    @State private var name: String
    @State private var mode: String
    @State private var addresses: String
    @State private var apps: String
    /// Full Windows paths from the panel or a file: kept as they are, a Mac cannot use them.
    @State private var windowsPaths: [AppRule]
    @State private var problem: String?
    @State private var confirmDelete = false

    init(ruleSet: RuleSet) {
        self.ruleSet = ruleSet
        _name = State(initialValue: ruleSet.name)
        _mode = State(initialValue: ruleSet.routing.mode)
        _addresses = State(initialValue: ruleSet.routing.destinations.joined(separator: "\n"))
        _apps = State(initialValue: ruleSet.routing.macApplications.map(\.name).joined(separator: "\n"))
        _windowsPaths = State(initialValue: ruleSet.routing.applications.filter { $0.executable != nil })
    }

    private var readOnly: Bool { ruleSet.builtin || ruleSet.managed }
    private var appLines: [String] { apps.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    private var changed: Bool {
        name != ruleSet.name || mode != ruleSet.routing.mode || lines != ruleSet.routing.destinations
            || appLines != ruleSet.routing.macApplications.map(\.name) || windowsPaths != ruleSet.routing.applications.filter { $0.executable != nil }
    }
    private var lines: [String] { addresses.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if readOnly {
                Text(ruleSet.name).font(.system(size: 15, weight: .semibold))
                Text(ruleSet.builtin ? "Встроенный набор: весь трафик идёт через VPN, кроме локальной сети. Его нельзя изменить." : "Набор задаёт администратор подписки. Изменить его нельзя, но можно создать личную копию.")
                    .font(.system(size: 12)).foregroundColor(Theme.muted).fixedSize(horizontal: false, vertical: true)
            } else {
                TextField("Название набора", text: $name).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
            }
            if !ruleSet.builtin {
                SegmentedChoice(options: [Choice("selective", "Через VPN — только эти"), Choice("general", "Через VPN всё, кроме этих")], selected: mode) { if !readOnly { mode = $0 } }
                    .frame(maxWidth: 440).disabled(readOnly)
                Text(mode == "selective" ? "Эти сайты и программы идут через VPN, всё остальное — напрямую." : "Эти сайты и программы идут напрямую, всё остальное — через VPN.")
                    .font(.system(size: 11)).foregroundColor(Theme.faint)
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Сайты и адреса").font(.system(size: 11)).foregroundColor(Theme.faint)
                        editor($addresses)
                        Text("example.com, *.example.com, 203.0.113.7 или 203.0.113.0/24. Сейчас: " + Plural.addresses(lines.count) + " из 256.")
                            .font(.system(size: 11)).foregroundColor(Theme.faint).fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Программы").font(.system(size: 11)).foregroundColor(Theme.faint)
                        editor($apps)
                        Text("Имя процесса как в «Мониторинге системы», например Jivo. Его вспомогательные процессы (Jivo Helper, Jivo Helper (GPU) …) входят сами.")
                            .font(.system(size: 11)).foregroundColor(Theme.faint).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !windowsPaths.isEmpty {
                    Text("Ещё " + String(windowsPaths.count) + " правил с полным путём Windows (C:\\…). На Mac они не действуют и сохраняются для Windows-клиента.")
                        .font(.system(size: 11)).foregroundColor(Theme.warning).fixedSize(horizontal: false, vertical: true)
                }
            } else { Spacer() }
            if let problem = problem { Text(problem).font(.system(size: 11)).foregroundColor(Theme.danger).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 8) {
                if readOnly {
                    Button("Создать копию", action: copy).buttonStyle(QuietButtonStyle())
                    if !ruleSet.builtin { Button("Экспорт…", action: exportFile).buttonStyle(QuietButtonStyle()) }
                } else {
                    Button("Импорт…", action: importFile).buttonStyle(QuietButtonStyle())
                    Button("Экспорт…", action: exportFile).buttonStyle(QuietButtonStyle())
                    Button("Удалить") { confirmDelete = true }.buttonStyle(QuietButtonStyle(tint: Theme.danger))
                    Spacer()
                    Button("Сохранить", action: save).buttonStyle(QuietButtonStyle(tint: Theme.accent)).disabled(!changed).keyboardShortcut("s", modifiers: .command)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog("Удалить набор «" + ruleSet.name + "»?", isPresented: $confirmDelete) {
            Button("Удалить", role: .destructive) { if model.change({ try $0.removeRuleSet(ruleSet.id) }) { model.editedRuleSetId = nil } }
            Button("Отмена", role: .cancel) {}
        }
    }

    private func editor(_ text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.system(size: 12, design: .monospaced))
            .scrollContentBackground(.hidden)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
            .disabled(readOnly)
    }

    /// The programs as rules: a program already in the set keeps its route, a new one follows the mode
    /// (only these through the VPN → «vpn», everything but these → «direct»).
    private func applicationRules() throws -> [AppRule] {
        var result = windowsPaths
        for line in appLines {
            let name: String
            do { name = try Routing.applicationName(line) }
            catch let error as FormatError { throw FormatError("«" + line + "»: " + error.message) }
            let known = ruleSet.routing.applications.first { $0.name?.lowercased() == name.lowercased() }
            result.append(AppRule(name: name, action: known?.action ?? (mode == "selective" ? "vpn" : "direct")))
        }
        return result
    }

    private func draft() throws -> Routing {
        var routing = Routing(mode: mode, destinations: lines, applications: try applicationRules())
        for line in lines {
            do { _ = try Routing.normalizeDestination(line) }
            catch let error as FormatError { throw FormatError("«" + line + "»: " + error.message) }
        }
        try routing.validate()
        return routing
    }

    private func save() {
        do {
            let routing = try draft()
            problem = nil
            let wasSelected = ruleSet.id == model.state.selectedRuleSetId
            let ok = model.change { state in
                if name.trimmingCharacters(in: .whitespaces) != ruleSet.name { try state.renameRuleSet(ruleSet.id, name) }
                try state.updateRuleSet(ruleSet.id, routing)
            }
            if ok {
                addresses = routing.destinations.joined(separator: "\n")
                apps = routing.macApplications.map(\.name).joined(separator: "\n")
                name = name.trimmingCharacters(in: .whitespaces)
                if wasSelected && model.isActive { model.say("Правила сохранены. Применятся при следующем подключении.") }
            }
        } catch { problem = (error as? FormatError)?.message ?? error.localizedDescription }
    }

    private func copy() {
        var created: RuleSet?
        let title = model.state.freeRuleSetName(ruleSet.builtin ? "Мои правила" : ruleSet.name)
        if model.change({ created = try $0.addRuleSet(title, ruleSet.builtin ? Routing(mode: "selective", destinations: []) : ruleSet.routing) }) { model.editedRuleSetId = created?.id }
    }

    private func exportFile() {
        do {
            let routing = try (readOnly ? ruleSet.routing : draft())
            let text = try RulesFile.export(routing)
            let panel = NSSavePanel()
            panel.title = "Экспорт правил"
            panel.nameFieldStringValue = ruleSet.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + ".netlanerules"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch { problem = (error as? FormatError)?.message ?? error.localizedDescription }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.title = "Импорт правил в этот набор"
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= 65536 else { throw FormatError("Пустой или слишком большой файл правил.") }
            let routing = try RulesFile.import(try String(contentsOf: url, encoding: .utf8))
            // The file replaces the draft; nothing is stored until «Сохранить».
            mode = routing.mode
            addresses = routing.destinations.joined(separator: "\n")
            apps = routing.macApplications.map(\.name).joined(separator: "\n")
            windowsPaths = routing.applications.filter { $0.executable != nil }
            problem = nil
        } catch { problem = (error as? FormatError)?.message ?? "Не удалось прочитать файл правил." }
    }
}
