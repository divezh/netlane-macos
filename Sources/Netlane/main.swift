import SwiftUI

// The freshly downloaded copy is started with «--apply-update <installed app> <pid>»: it replaces the
// installed app with itself and opens it (see Updater.apply). Everything else is the normal start.
func applyUpdateIfAsked() {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--apply-update"), arguments.count > index + 2, let pid = Int32(arguments[index + 2]) else { return }
    Updater.apply(target: arguments[index + 1], pid: pid)
}

applyUpdateIfAsked()
NetlaneApp.main()
