// swift-tools-version:5.9
import PackageDescription

var targets: [Target] = [
    // Everything that does not need a window: profiles, subscriptions, rules, the engine config.
    // Foundation only, so the tests also run on Linux.
    .target(name: "NetlaneCore"),
    // The root helper that starts the pinned engine; installed once with an administrator password.
    .executableTarget(name: "NetlaneHelper", dependencies: ["NetlaneCore"]),
    .testTarget(name: "NetlaneCoreTests", dependencies: ["NetlaneCore"]),
]
#if os(macOS)
// The SwiftUI application itself.
targets.append(.executableTarget(name: "Netlane", dependencies: ["NetlaneCore"]))
#endif

let package = Package(name: "Netlane", platforms: [.macOS(.v13)], targets: targets)
