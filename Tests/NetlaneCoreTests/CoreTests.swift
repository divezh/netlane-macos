import XCTest
@testable import NetlaneCore

let fixture = "hostname = \"vpn.example.com\"\naddresses = [\"vpn.example.com:443\"]\nhas_ipv6 = false\nusername = \"alice\"\npassword = \"unique-test-secret-123\"\nskip_verification = false\nupstream_protocol = \"http3\"\nanti_dpi = true\n"

/// Builds a tt:// link the way the panel does: tag, length (QUIC varint), value.
func link(version: UInt8 = 1, skip: Bool = false, host: String = "vpn.example.com", password: String = String(repeating: "x", count: 128), transport: UInt8 = 2, name: String? = nil, extraTag: UInt8? = nil) -> String {
    var bytes: [UInt8] = []
    func field(_ tag: UInt8, _ value: [UInt8]) {
        bytes.append(tag)
        if value.count < 64 { bytes.append(UInt8(value.count)) } else { bytes.append(UInt8((value.count >> 8) | 64)); bytes.append(UInt8(value.count & 255)) }
        bytes += value
    }
    field(0, [version]); field(1, Array(host.utf8)); field(2, Array((host + ":443").utf8)); field(4, [skip ? 1 : 0])
    field(5, Array("alice".utf8)); field(6, Array(password.utf8)); field(9, [transport]); field(10, [1])
    if let name = name { field(12, Array(name.utf8)) }
    if let extra = extraTag { field(extra, [1]) }
    return "tt://?" + Data(bytes).base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
}

func feed(hours: Int = 6, _ servers: [[String]]) -> String {
    "{\"version\":1,\"name\":\"🇳🇱 Амстердам\",\"update_hours\":\(hours),\"servers\":[" + servers.map { "{\"id\":\"\($0[0])\",\"name\":\"\($0[1])\",\"country\":\"\($0[2])\",\"link\":\"\($0[3])\"}" }.joined(separator: ",") + "]}"
}
func with(_ json: String, _ key: String, _ block: String) -> String { String(json.dropLast()) + ",\"\(key)\":" + block + "}" }

final class ProfileTests: XCTestCase {
    func testTomlImport() throws {
        let p = try Profile.import(fixture)
        XCTAssertEqual(p.hostname, "vpn.example.com"); XCTAssertEqual(p.address, "vpn.example.com:443")
        XCTAssertEqual(p.username, "alice"); XCTAssertEqual(p.transport, "http3"); XCTAssertTrue(p.antiDpi); XCTAssertNil(p.name)
        XCTAssertEqual(p.endpoint.host, "vpn.example.com"); XCTAssertEqual(p.endpoint.port, 443)
    }
    func testLinkImport() throws {
        let p = try Profile.import(link(name: "🇳🇱 Амстердам"))
        XCTAssertEqual(p.hostname, "vpn.example.com"); XCTAssertEqual(p.password.count, 128); XCTAssertEqual(p.transport, "http3"); XCTAssertTrue(p.antiDpi)
        let server = Server.from(p)
        XCTAssertEqual(server.name, "Амстердам"); XCTAssertEqual(server.country, "NL")
        XCTAssertEqual(Server.from(try Profile.import(link())).name, "vpn.example.com")
        XCTAssertEqual(try Profile.import(link(transport: 1)).transport, "http2")
    }
    func testUnsafeProfilesRejected() {
        for bad in [link(version: 2), link(skip: true), link(extraTag: 7), link(transport: 3), link(password: "short"), "tt://?", "tt://?!!!", "tt://?AAAAA",
                    fixture.replacingOccurrences(of: "skip_verification = false", with: "skip_verification = true"),
                    fixture + "certificate = \"x\"\n", fixture.replacingOccurrences(of: "vpn.example.com:443", with: "vpn.example.com:443/path"),
                    fixture.replacingOccurrences(of: "\"alice\"", with: "\"al ice\""), fixture.replacingOccurrences(of: "http3", with: "quic"), "", "hello"] {
            XCTAssertThrowsError(try Profile.import(bad), bad)
        }
    }
    func testAddresses() {
        for good in ["vpn.example.com", "vpn.example.com:443", "203.0.113.5:8443", "[2001:db8::1]:443"] { XCTAssertTrue(Profile.validAddress(good), good) }
        for bad in ["", "a b:443", "user@host:443", "host:0", "host:70000", "host:", "https://host", "host/path", "2001:db8::1", "[host]:443", "host:44a"] { XCTAssertFalse(Profile.validAddress(bad), bad) }
    }
    func testEngineConfig() throws {
        var p = try Profile.import(fixture)
        p.dnsServers = ["1.1.1.1", "tls://dns.example"]
        p.routing = Routing(mode: "selective", destinations: ["Example.com", "10.1.0.0/16"], applications: [AppRule(name: "telegram.exe", action: "vpn")])
        let config = try p.engineConfig()
        XCTAssertTrue(config.hasPrefix("loglevel = \"info\"\nkillswitch_enabled = true\ndns_all_through_vpn = true\nvpn_mode = \"selective\"\nexclusions = ["))
        p.dnsServers = []
        XCTAssertFalse(try p.engineConfig().contains("dns_all_through_vpn"))
        p.dnsServers = ["1.1.1.1", "tls://dns.example"]
        XCTAssertTrue(config.contains("upstream_protocol = \"http3\"\nanti_dpi = true\ndns_upstreams = [\"1.1.1.1\", \"tls://dns.example\"]\n[listener.tun]\nchange_system_dns = true\nincluded_routes = [\"0.0.0.0/0\", \"2000::/3\"]\n"))
        XCTAssertTrue(config.contains("exclusions = [\"example.com\", \"10.1.0.0/16\"]\n[[application_rules]]\nprocess_name = \"telegram\"\naction = \"vpn\"\n[endpoint]\n"))
        XCTAssertFalse(config.contains("device_name"))
        XCTAssertTrue(config.contains("skip_verification = false"))
        let socks = try p.engineConfig(socksPort: 18080)
        XCTAssertFalse(socks.contains("application_rules"))
        XCTAssertTrue(socks.contains("killswitch_enabled = false") && socks.hasSuffix("[listener.socks]\naddress = \"127.0.0.1:18080\"\n"))
        XCTAssertThrowsError(try p.engineConfig(socksPort: 80))
        let masked = Profile.mask(config)
        XCTAssertFalse(masked.contains("unique-test-secret-123")); XCTAssertTrue(masked.contains("password = \"***\""))
    }
    func testMacApplicationRules() throws {
        // The rule set from the panel: Windows names; on a Mac they become process names.
        var routing = Routing(mode: "selective", destinations: [], applications: [
            AppRule(name: "UIS Operator Workplace.exe", action: "vpn"), AppRule(name: "Jivo.EXE", action: "vpn"),
            AppRule(executable: "C:\\Apps\\direct.exe", action: "direct"), AppRule(name: "exolve-messenger.exe", action: "direct")])
        try routing.validate()
        XCTAssertEqual(routing.macApplications.map(\.name), ["UIS Operator Workplace", "Jivo", "exolve-messenger"])
        XCTAssertEqual(routing.windowsOnlyApplications, 1)
        XCTAssertEqual(routing.summary, "Через VPN: 3 программы")
        let rules = try routing.engineConfig().applicationRules
        XCTAssertEqual(rules, "[[application_rules]]\nprocess_name = \"UIS Operator Workplace\"\naction = \"vpn\"\n[[application_rules]]\nprocess_name = \"Jivo\"\naction = \"vpn\"\n[[application_rules]]\nprocess_name = \"exolve-messenger\"\naction = \"direct\"\n")
        XCTAssertEqual(try Routing.applicationName(" Jivo "), "Jivo.exe")
        XCTAssertEqual(try Routing.applicationName("UIS Operator Workplace Helper (GPU)"), "UIS Operator Workplace Helper (GPU).exe")
        XCTAssertEqual(try Routing.applicationName("Jivo.exe"), "Jivo.exe")
        for bad in ["", "  ", "/Applications/Jivo.app", "a:b", "a\u{1}"] { XCTAssertThrowsError(try Routing.applicationName(bad), bad) }
    }
    func testTomlQuoteIsNotJson() {
        XCTAssertEqual(Text.tomlQuote("a/b\"c\\d\n\u{1}é"), "\"a/b\\\"c\\\\d\\n\\u0001é\"")
    }
}

final class RoutingTests: XCTestCase {
    func testDestinations() throws {
        XCTAssertEqual(try Routing.normalizeDestination("Example.COM"), "example.com")
        XCTAssertEqual(try Routing.normalizeDestination("*.example.com"), "*.example.com")
        XCTAssertEqual(try Routing.normalizeDestination("10.0.0.0/8"), "10.0.0.0/8")
        XCTAssertEqual(try Routing.normalizeDestination("8.8.8.8"), "8.8.8.8")
        for bad in ["", "a b", "example", "http://example.com", "example.com/24", "1.2.3", "1.2.3.4.5", "01.2.3.4", "256.1.1.1", "1.2.3.4/33", "1.2.3.4/x", "2001:db8::1", "-a.com", "a..com", "1.2.3.4/8/9", String(repeating: "a", count: 64) + ".com"] {
            XCTAssertThrowsError(try Routing.normalizeDestination(bad), bad)
        }
    }
    func testValidate() {
        var duplicate = Routing(mode: "general", destinations: ["a.com", "A.com"])
        XCTAssertThrowsError(try duplicate.validate())
        var mode = Routing(mode: "other", destinations: [])
        XCTAssertThrowsError(try mode.validate())
        var apps = Routing(mode: "general", destinations: [], applications: [AppRule(executable: "C:\\Apps\\a.exe", action: "vpn"), AppRule(name: "b.exe", action: "direct")])
        XCTAssertNoThrow(try apps.validate())
        var both = Routing(mode: "general", destinations: [], applications: [AppRule(executable: "C:\\a.exe", name: "a.exe", action: "vpn")])
        XCTAssertThrowsError(try both.validate())
        XCTAssertEqual(Routing(mode: "selective", destinations: ["a.com", "b.com"]).summary, "Через VPN: 2 адреса")
        XCTAssertEqual(Routing().summary, "Весь трафик через VPN")
    }
    func testRulesFile() throws {
        let routing = Routing(mode: "selective", destinations: ["example.com"], applications: [AppRule(name: "telegram.exe", action: "vpn")])
        let text = try RulesFile.export(routing)
        XCTAssertEqual(try RulesFile.import(text), routing)
        // A file written by the Windows client (PascalCase keys, nulls) and by the former product name.
        let windows = "{\"Format\":\"netlane-rules\",\"Version\":1,\"Routing\":{\"Mode\":\"general\",\"Destinations\":[\"a.com\"],\"Applications\":[{\"Executable\":\"C:\\\\Apps\\\\a.exe\",\"Name\":null,\"Action\":\"direct\"}]}}"
        XCTAssertEqual(try RulesFile.import(windows).applications.first?.executable, "C:\\Apps\\a.exe")
        XCTAssertEqual(try RulesFile.import("\u{FEFF}{\"format\":\"wintrusttunnel-rules\",\"version\":1,\"routing\":{\"mode\":\"general\",\"destinations\":[]}}").mode, "general")
        for bad in ["{\"format\":\"other\"}", "{\"format\":\"netlane-rules\",\"version\":2,\"routing\":{}}", "{\"format\":\"netlane-rules\",\"version\":1}", "", "["] {
            XCTAssertThrowsError(try RulesFile.import(bad), bad)
        }
    }
}

final class DnsTests: XCTestCase {
    func testNormalize() throws {
        let cases = ["1.1.1.1": "1.1.1.1", " 8.8.8.8 ": "8.8.8.8", "9.9.9.9:53": "9.9.9.9:53", "tls://Dns.Example": "tls://dns.example", "tls://dns.example:853": "tls://dns.example:853",
                     "https://dns.example/dns-query": "https://dns.example/dns-query", "https://DNS.example": "https://dns.example/", "https://dns.example:443/dns-query": "https://dns.example/dns-query",
                     "quic://dns.example": "quic://dns.example", "2606:4700:4700::1111": "2606:4700:4700::1111", "[2606:4700:4700::1111]:53": "[2606:4700:4700::1111]:53", "tcp://1.1.1.1:53": "tcp://1.1.1.1:53"]
        for (input, expected) in cases { XCTAssertEqual(try DnsSettings.normalizeServer(input), expected, input) }
        for bad in ["", "dns.example", "dns.example:53", "1.1.1.1:", "1.1.1.1:0", "1.1.1.1:99999", "ftp://dns.example", "tls://dns.example/path", "https://user@dns.example/", "192.168.1.1", "10.0.0.1:53", "127.0.0.1",
                    "0.0.0.0", "255.255.255.255", "tls://192.168.0.1", "tls://", "a b", "::1", "fe80::1", "fd00::1", "100.64.0.1", "1.1.1.1#x", "tls://1.2.3", "01.1.1.1"] {
            XCTAssertThrowsError(try DnsSettings.normalizeServer(bad), bad)
        }
    }
    func testLists() throws {
        XCTAssertEqual(try DnsSettings.parse("1.1.1.1\n\n  8.8.8.8\r\n"), ["1.1.1.1", "8.8.8.8"])
        XCTAssertThrowsError(try DnsSettings.normalize(["1.1.1.1", "1.1.1.1"]))
        XCTAssertThrowsError(try DnsSettings.normalize((1...9).map { "1.1.1.\($0)" }))
        var dropped: [String] = []
        XCTAssertEqual(DnsSettings.sanitize(["1.1.1.1", "192.168.1.1", "1.1.1.1", "nonsense"], dropped: &dropped), ["1.1.1.1"])
        XCTAssertEqual(dropped, ["192.168.1.1", "1.1.1.1", "nonsense"])
    }
}

final class StateTests: XCTestCase {
    func server(_ host: String = "vpn.example.com") throws -> Server { Server.from(try Profile.import(fixture.replacingOccurrences(of: "vpn.example.com", with: host))) }

    func testFreshState() throws {
        var state = ClientState()
        XCTAssertNoThrow(try state.validate())
        XCTAssertEqual(state.ruleSets.count, 1); XCTAssertTrue(state.ruleSets[0].builtin); XCTAssertEqual(state.selectedRuleSet.name, "Весь трафик")
        XCTAssertNil(state.selectedServer); XCTAssertTrue(state.killSwitch); XCTAssertTrue(state.keepInMenuBar)
        XCTAssertThrowsError(try state.sessionProfile())
    }
    func testServersAndRoundTrip() throws {
        var state = ClientState()
        let x = try state.addServer(try server(), .addCopy), y = try state.addServer(try server("ams.example.com"), .addCopy)
        XCTAssertEqual(state.selectedServerId, y.id)
        state.openAtLogin = true; state.dnsServers = ["1.1.1.1"]
        let again = try ClientState.decoded(try state.encoded())
        XCTAssertEqual(again, state); XCTAssertEqual(again.selectedServer?.hostname, "ams.example.com")
        // The same host and user again: update in place, or a copy when asked.
        var changed = try server("AMS.example.com"); changed.password = "another-password-1"
        XCTAssertEqual(state.findDuplicate(changed)?.id, y.id)
        try state.addServer(changed, .update)
        XCTAssertEqual(state.servers.count, 2); XCTAssertEqual(state.servers[1].password, "another-password-1")
        try state.addServer(changed, .addCopy)
        XCTAssertEqual(state.servers.count, 3)
        try state.removeServer(state.selectedServerId!); try state.removeServer(y.id)
        XCTAssertEqual(state.selectedServerId, x.id)
        try state.removeServer(x.id)
        XCTAssertNil(state.selectedServerId)
        XCTAssertThrowsError(try ClientState.decoded(Data("{}".utf8)))
    }
    func testRuleSets() throws {
        var state = ClientState()
        try state.addServer(try server(), .addCopy)
        let mine = try state.addRuleSet("Мои правила", Routing(mode: "selective", destinations: ["example.com"]))
        XCTAssertThrowsError(try state.addRuleSet("мои правила"))
        XCTAssertEqual(state.freeRuleSetName("Мои правила"), "Мои правила 2")
        XCTAssertThrowsError(try state.updateRuleSet(state.builtinRuleSet.id, Routing()))
        XCTAssertThrowsError(try state.removeRuleSet(state.builtinRuleSet.id))
        try state.selectRuleSet(mine.id)
        state.dnsServers = ["9.9.9.9"]; state.killSwitch = false; state.antiDpi = true
        let profile = try state.sessionProfile()
        XCTAssertEqual(profile.routing.mode, "selective"); XCTAssertEqual(profile.dnsServers, ["9.9.9.9"]); XCTAssertFalse(profile.killSwitch); XCTAssertTrue(profile.antiDpi)
        try state.renameRuleSet(mine.id, "Офис")
        XCTAssertEqual(state.selectedRuleSet.name, "Офис")
        try state.removeRuleSet(mine.id)
        XCTAssertTrue(state.selectedRuleSet.builtin)
    }
    func testTransportChoice() throws {
        var s = try server()
        XCTAssertEqual(s.effectiveTransport, "http3")
        s.chosenTransport = "http2"; XCTAssertEqual(s.effectiveTransport, "http2")
        s.chosenTransport = "auto"; XCTAssertEqual(s.effectiveTransport, "http3"); XCTAssertTrue(s.isAuto)
        s.autoTransport = "http2"; XCTAssertEqual(s.toProfile().transport, "http2")
        s.chosenTransport = "weird"; try s.validate(); XCTAssertNil(s.chosenTransport)
    }
}

final class SubscriptionTests: XCTestCase {
    let ams = link(host: "ams.example.com", password: "password-12345", transport: 1)
    let fra = link(host: "fra.example.com", password: "password-12345", transport: 1)
    let url = "https://ams.example.com/abcdefghijklmnopqrstuvwxyz/sub/token_1"

    func testUrl() {
        XCTAssertTrue(Subscription.looksLikeUrl(url)); XCTAssertTrue(Subscription.looksLikeUrl("  " + url + "\n"))
        for bad in ["http://a.example/sub/x", "https://a.example/sub/", "https://a.example/other/x", "https://u:p@a.example/sub/x", "tt://?abc", "", "https://a.example/sub/x y"] { XCTAssertFalse(Subscription.looksLikeUrl(bad), bad) }
    }
    func testParse() throws {
        let parsed = try SubscriptionFeed.parse(feed([["main", "🇳🇱 Амстердам", "", ams], ["two", "Франкфурт", "DE", fra]]))
        XCTAssertEqual(parsed.name, "🇳🇱 Амстердам"); XCTAssertEqual(parsed.updateHours, 6)
        XCTAssertEqual(parsed.servers.map(\.name), ["Амстердам", "Франкфурт"]); XCTAssertEqual(parsed.servers.map(\.country), ["NL", "DE"])
        XCTAssertEqual(parsed.servers[0].remoteId, "main"); XCTAssertEqual(parsed.servers[0].transport, "http2")
        let plain = feed([["main", "A", "", ams]])
        for bad in [plain.replacingOccurrences(of: "\"version\":1", with: "\"version\":2"), plain.replacingOccurrences(of: "\"version\":1", with: "\"version\":true"), "not json", "{\"version\":1}",
                    feed([["main", "A", "", ams], ["main", "B", "", fra]]), feed([["bad id", "A", "", ams]]), feed([["main", "A", "", "https://x"]]), feed([["main", "A", "", link(skip: true)]])] {
            XCTAssertThrowsError(try SubscriptionFeed.parse(bad), bad)
        }
    }
    func testMergeAndOrphans() throws {
        var state = ClientState()
        let sub = try state.addSubscription(url)
        XCTAssertEqual(try state.addSubscription(" " + url).id, sub.id)
        var result = try state.applyFeed(sub.id, try SubscriptionFeed.parse(feed([["main", "Амстердам", "NL", ams], ["two", "Франкфурт", "DE", fra]])), connectedServerId: nil)
        XCTAssertEqual(result.added, 2); XCTAssertEqual(state.servers.count, 2); XCTAssertEqual(state.selectedServer?.name, "Амстердам")
        XCTAssertEqual(state.subscriptions[0].displayName, "Амстердам"); XCTAssertNotNil(state.subscriptions[0].updatedDate); XCTAssertFalse(state.subscriptions[0].isDue(now: Date()))
        XCTAssertTrue(state.subscriptions[0].isDue(now: Date().addingTimeInterval(7 * 3600)))
        // The user's transport choice survives a refresh; a changed password restarts the connected server.
        let connected = state.servers[0].id
        try state.updateServer(connected) { $0.chosenTransport = "http3" }
        let newPassword = link(host: "ams.example.com", password: "password-67890", transport: 1)
        result = try state.applyFeed(sub.id, try SubscriptionFeed.parse(feed([["main", "Амстердам", "NL", newPassword], ["two", "Франкфурт", "DE", fra]])), connectedServerId: connected)
        XCTAssertEqual(result, FeedResult(added: 0, updated: 1, removed: 0, currentChanged: true, settingsChanged: false))
        XCTAssertEqual(state.servers[0].chosenTransport, "http3"); XCTAssertEqual(state.servers[0].password, "password-67890")
        // The connected server leaves the feed: kept as an orphan until the session ends.
        result = try state.applyFeed(sub.id, try SubscriptionFeed.parse(feed([["two", "Франкфурт", "DE", fra]])), connectedServerId: connected)
        XCTAssertEqual(result.removed, 1); XCTAssertTrue(state.servers.first { $0.id == connected }!.orphaned)
        state.dropOrphans()
        XCTAssertEqual(state.servers.map(\.name), ["Франкфурт"]); XCTAssertEqual(state.selectedServer?.name, "Франкфурт")
        try state.removeSubscription(sub.id, connectedServerId: nil)
        XCTAssertTrue(state.servers.isEmpty); XCTAssertNil(state.selectedServerId)
    }
    func testSharedSettings() throws {
        let plain = feed([["main", "Main", "NL", ams]])
        let extra = #"{"version":1,"revision":1,"dns_servers":["1.1.1.1"],"rule_sets":[{"id":"work","name":"Рабочие","routing":{"Mode":"selective","Destinations":["example.com"],"Applications":[{"Name":"telegram.exe","Action":"vpn"}]}}]}"#
        let parsed = try SubscriptionFeed.parse(with(plain, "client_settings", extra))
        var state = ClientState()
        state.dnsServers = ["8.8.8.8"]
        try state.addRuleSet("Рабочие")
        let manual = try state.addServer(Server.from(try Profile.import(fixture)), .addCopy)
        let sub = try state.addSubscription(url)
        let result = try state.applyFeed(sub.id, parsed, connectedServerId: nil)
        XCTAssertTrue(result.settingsChanged)
        // A managed set may share its name with a personal one; it is offered only with its own servers.
        XCTAssertEqual(state.ruleSets.filter { $0.name == "Рабочие" }.count, 2)
        XCTAssertEqual(state.availableRuleSets.count, 2)
        let managed = state.ruleSets.first { $0.managed }!
        try state.selectServer(state.servers.first { $0.subscriptionId == sub.id }!.id)
        XCTAssertEqual(state.availableRuleSets.count, 3)
        try state.selectRuleSet(managed.id)
        XCTAssertEqual(try state.sessionProfile().dnsServers, ["1.1.1.1"]); XCTAssertTrue(state.effectiveDns(for: state.selectedServer).managed)
        XCTAssertThrowsError(try state.updateRuleSet(managed.id, Routing()))
        try state.selectServer(manual.id)
        XCTAssertTrue(state.selectedRuleSet.builtin, "a managed set is not kept for a server of another source")
        XCTAssertEqual(try state.sessionProfile().dnsServers, ["8.8.8.8"])
        XCTAssertFalse(try state.applyFeed(sub.id, parsed, connectedServerId: nil).settingsChanged)
        try state.removeSubscription(sub.id, connectedServerId: nil)
        XCTAssertFalse(state.ruleSets.contains { $0.managed })
        for bad in [#"{"version":2,"revision":1,"rule_sets":[]}"#, #"{"version":1,"revision":-1,"rule_sets":[]}"#, #"{"version":1,"revision":1,"rule_sets":[],"dns_servers":["192.168.1.1"]}"#,
                    #"{"version":1,"revision":1,"rule_sets":[{"id":"a","name":"A"}]}"#, #"{"version":1,"revision":1,"rule_sets":[{"id":"a","name":"A","routing":{"Mode":"x"}}]}"#] {
            XCTAssertThrowsError(try SubscriptionFeed.parse(with(plain, "client_settings", bad)), bad)
        }
    }
    func testAccount() throws {
        let plain = feed([["main", "Main", "NL", ams]])
        let utc = TimeZone(identifier: "UTC")!
        let now = Account.parseDate("2026-11-05T10:00:00Z")!
        let parsed = try SubscriptionFeed.parse(with(plain, "account", #"{"status":"active","expires_at":"2026-11-17T00:00:00Z","quota_bytes":53687091200,"quota_used_bytes":13314398617,"quota_month":"2026-11"}"#))
        XCTAssertEqual(parsed.accountStatus, "active"); XCTAssertEqual(parsed.quotaBytes, 50 << 30); XCTAssertEqual(parsed.quotaMonth, "2026-11")
        XCTAssertNil(try SubscriptionFeed.parse(plain).accountStatus)
        let odd = try SubscriptionFeed.parse(with(plain, "account", #"{"status":"vip","quota_bytes":5}"#))
        XCTAssertNil(odd.accountStatus); XCTAssertEqual(odd.quotaBytes, 0)
        let bad = try SubscriptionFeed.parse(with(plain, "account", #"{"status":"active","expires_at":"soon","quota_bytes":-5,"quota_used_bytes":"x","quota_month":"11/2026"}"#))
        XCTAssertEqual(bad.accountStatus, "active"); XCTAssertNil(bad.expiresAt); XCTAssertEqual(bad.quotaBytes, 0); XCTAssertNil(bad.quotaMonth)
        var state = ClientState()
        let id = try state.addSubscription(url).id
        try state.applyFeed(id, parsed, connectedServerId: nil)
        var sub = state.subscriptions[0]
        XCTAssertEqual(Account.summary(sub, now: now, zone: utc), "до 17.11 · 12,4/50 ГБ")
        XCTAssertEqual(Account.level(sub, now: now), .normal)
        XCTAssertEqual(Account.details(sub, zone: utc), "Доступ до 17.11.2026 00:00 · Трафик за ноябрь: 12,4 из 50 ГБ (25%)")
        sub.quotaUsedBytes = 300 << 20; XCTAssertEqual(Account.usage(sub, "/"), "300 МБ/50 ГБ"); sub.quotaUsedBytes = 13314398617
        XCTAssertEqual(Account.level(sub, now: Account.parseDate("2026-11-15T00:00:00Z")!), .warning)
        XCTAssertNotNil(Account.warning(sub, now: Account.parseDate("2026-11-15T00:00:00Z")!, zone: utc))
        sub.quotaUsedBytes = 46 << 30; XCTAssertEqual(Account.level(sub, now: now), .warning)
        XCTAssertEqual(Account.size(512 << 20), "512 МБ"); XCTAssertEqual(Account.size(3 << 30), "3 ГБ"); XCTAssertEqual(Account.size(25 << 30), "25 ГБ")
        // Access ended: no servers, the reason instead.
        try state.applyFeed(id, try SubscriptionFeed.parse(#"{"version":1,"servers":[],"account":{"status":"expired","expires_at":"2026-11-03T10:00:00Z"}}"#), connectedServerId: nil)
        XCTAssertTrue(state.servers.isEmpty); XCTAssertTrue(Account.blocked(state.subscriptions[0]))
        XCTAssertEqual(Account.summary(state.subscriptions[0], now: now, zone: utc), "доступ истёк 03.11.2026")
        XCTAssertEqual(Account.level(state.subscriptions[0], now: now), .danger)
        XCTAssertNotNil(Account.parseDate("2026-11-17T03:00:00.1234567Z")); XCTAssertNotNil(Account.parseDate("2026-11-17T03:00:00+03:00")); XCTAssertNil(Account.parseDate("1999-01-01T00:00:00Z"))
    }
}

final class SessionTests: XCTestCase {
    func testFormats() {
        XCTAssertEqual(SessionStats.duration(42 * 60 + 17), "00:42:17"); XCTAssertEqual(SessionStats.duration(100 * 3600 + 5), "100:00:05"); XCTAssertEqual(SessionStats.duration(-5), "00:00:00")
        XCTAssertEqual(SessionStats.bytes(0), "0 Б"); XCTAssertEqual(SessionStats.bytes(1023), "1023 Б"); XCTAssertEqual(SessionStats.bytes(1024), "1,0 КБ")
        XCTAssertEqual(SessionStats.bytes(1024 * 1024 - 1), "1,0 МБ"); XCTAssertEqual(SessionStats.bytes(1932735283), "1,8 ГБ")
        XCTAssertEqual(SessionStats.rate(1_677_721.6), "1,6 МБ/с")
        XCTAssertEqual(SessionStats.line(seconds: 2537, traffic: (1932735283, 220200960)), "00:42:17 · ↓ 1,8 ГБ · ↑ 210,0 МБ")
        XCTAssertEqual(SessionStats.line(seconds: 5, traffic: nil), "00:00:05")
        XCTAssertEqual(SessionStats.ago(30), "только что"); XCTAssertEqual(SessionStats.ago(125), "2 мин назад")
        XCTAssertEqual(SessionStats.span(30), "меньше минуты"); XCTAssertEqual(SessionStats.span(3 * 3600 + 5 * 60), "3 ч 05 мин")
    }
    func testTrafficMeter() {
        var meter = TrafficMeter()
        meter.start(received: 1000, sent: 100)
        meter.update(received: 3000, sent: 200, time: 10)
        XCTAssertEqual(meter.down, 2000); XCTAssertEqual(meter.up, 100)
        meter.update(received: 5000, sent: 400, time: 11)
        XCTAssertEqual(meter.downRate, 2000); XCTAssertEqual(meter.upRate, 200)
        meter.update(received: 5100, sent: 400, time: 11.1)
        XCTAssertEqual(meter.downRate, 2000, "a reading right after the previous one keeps the rate")
        // The tunnel interface was recreated: counters restart, the session total keeps growing.
        meter.update(received: 500, sent: 50, time: 13)
        XCTAssertEqual(meter.down, 4600); XCTAssertEqual(meter.up, 350)
    }
    func testPublicIp() throws {
        let ip = try PublicIp.parse("fl=1\nh=www.cloudflare.com\nip=185.12.3.4\nts=1\nloc=nl\n")
        XCTAssertEqual(ip.text, "185.12.3.4 · Нидерланды")
        XCTAssertEqual(try PublicIp.parse("ip=2a00:1450::1\nloc=XX").text, "2a00:1450::1")
        XCTAssertThrowsError(try PublicIp.parse("loc=NL")); XCTAssertThrowsError(try PublicIp.parse("ip=<html>"))
    }
    func testEngineLines() {
        XCTAssertEqual(EngineEvent.classify("05.11.2026 10:00:00.123456 INFO  [1] Successfully connected to endpoint"), .connected)
        XCTAssertEqual(EngineEvent.classify("05.11.2026 10:00:00.123456 INFO  [1] Waiting recovery: to next=3000ms error=x"), .reconnecting(seconds: 3))
        XCTAssertEqual(EngineEvent.classify("05.11.2026 10:00:00.123456 ERROR [1] Failed to connect"), .failure)
        XCTAssertNil(EngineEvent.classify("05.11.2026 10:00:00.123456 WARN  [1] Failed to send DNS directly"))
        XCTAssertEqual(EngineEvent.classify("Error: cannot open config"), .failure)
        XCTAssertNil(EngineEvent.classify("05.11.2026 10:00:00.123456 INFO  [1] Listening"))
    }
    func testFlagsAndVersions() {
        XCTAssertEqual(ServerName.flag("NL"), "🇳🇱"); XCTAssertNil(ServerName.flag("nl")); XCTAssertNil(ServerName.flag(nil))
        XCTAssertEqual(ServerName.split("  🇩🇪  Франкфурт ").country, "DE"); XCTAssertNil(ServerName.split("🇩🇪").name); XCTAssertNil(ServerName.split("Токио").country)
        XCTAssertTrue(AppVersion("0.10.0")! > AppVersion("0.9.9")!); XCTAssertEqual(AppVersion("1.0"), AppVersion("1.0.0"))
        for bad in ["1", "1.x", "1..2", "v1.2", "1.2.3.4.5", ""] { XCTAssertNil(AppVersion(bad), bad) }
    }
}

final class UpdateTests: XCTestCase {
    let sha = String(repeating: "ab", count: 32)
    func testNotes() {
        XCTAssertEqual(UpdateFeed.releaseNotes("Новое:\n\n- Первое `x`.\r\n- **Второе**.\n\nПроверка происхождения"), "Первое x. Второе.")
        XCTAssertNil(UpdateFeed.releaseNotes("## заголовок\nтекст")); XCTAssertNil(UpdateFeed.releaseNotes(nil))
        XCTAssertEqual(UpdateFeed.releaseUrl, "https://api.github.com/repos/divezh/netlane-macos/releases/latest")
        let m = UpdateManifest(version: "0.7.5", url: "https://github.com/x.zip", sha256: sha, notes: nil, mirror: nil)
        XCTAssertTrue(m.isNewer(than: "0.7.4")); XCTAssertFalse(m.isNewer(than: "0.7.5")); XCTAssertFalse(m.isNewer(than: "0.10.0"))
    }
    func testRelease() throws {
        let release = "{\"tag_name\":\"v0.8.0\",\"draft\":false,\"prerelease\":false,\"body\":\"- Быстрее.\",\"assets\":[{\"name\":\"other.zip\"},{\"name\":\"Netlane-macos.zip\",\"browser_download_url\":\"https://github.com/d/n/releases/download/v0.8.0/Netlane-macos.zip\",\"digest\":\"sha256:\(sha)\"}]}"
        let m = try UpdateFeed.parseRelease(release)
        XCTAssertEqual(m.version, "0.8.0"); XCTAssertEqual(m.sha256, sha); XCTAssertEqual(m.notes, "Быстрее.")
        XCTAssertThrowsError(try UpdateFeed.parseRelease(release.replacingOccurrences(of: "\"prerelease\":false", with: "\"prerelease\":true")))
        XCTAssertThrowsError(try UpdateFeed.parseRelease(release.replacingOccurrences(of: "Netlane-macos.zip\",\"browser", with: "X.zip\",\"browser")))
        XCTAssertThrowsError(try UpdateFeed.parseRelease(release.replacingOccurrences(of: "sha256:", with: "md5:")))
    }
}

final class HelperProtocolTests: XCTestCase {
    func testRoundTrip() throws {
        var profile = try Profile.import(fixture)
        profile.routing = Routing(mode: "selective", destinations: ["example.com"])
        let messages: [HelperProtocol.Message] = [.hello(version: nil, engine: nil), .hello(version: "0.7.0", engine: "1.1.11"), .start(profile), .stop,
                                                 .event(.reconnecting, detail: "3"), .event(.stopped, detail: nil), .log("line \"quoted\" \\ end"), .tunnel("utun7")]
        for message in messages {
            let line = HelperProtocol.encode(message)
            XCTAssertFalse(line.contains("\n"))
            XCTAssertEqual(HelperProtocol.decode(line), message, line)
        }
    }
    func testBadMessages() {
        for bad in ["", "STOP", "{}", "{\"type\":\"run\",\"command\":\"rm\"}", "{\"type\":\"start\"}", "{\"type\":\"start\",\"profile\":{\"hostname\":\"x\"}}",
                    "{\"type\":\"event\",\"value\":\"WHATEVER\"}", "{\"type\":\"tunnel\",\"name\":\"../etc\"}"] {
            XCTAssertNil(HelperProtocol.decode(bad), bad)
        }
        // A profile that fails the checks (TLS name with a path) never reaches the engine.
        var profile = try! Profile.import(fixture)
        profile.address = "vpn.example.com:443/x"
        XCTAssertNil(HelperProtocol.decode(HelperProtocol.encode(.start(profile))))
    }
}
