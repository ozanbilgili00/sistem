import Foundation
import Testing
@testable import SystemKit

@Suite("Sunucu girdi doğrulama")
struct ServerInputTests {
    static let hostile = [
        "-oProxyCommand=touch /tmp/x", "-o", "-", "--", "-host", "a b", "a;b", "a&b", "a|b", "$(id)", "`id`", "a\nb", "a\rb", "a\tb",
        "a'b", "a\"b", "a\\b", "a/b", "*.example.com", "a@b", "[::1]", "", "   ", "..", "a..b", ".a", "a.", "host-", "-.a", "a.-b",
        "ünicode.example.com", "::1%en0", "fe80::1%lo0", "1:2:3:4:5:6:7:8:9", "g::1", "::1;ls", "a:b",
        String(repeating: "a", count: 300), String(repeating: "a", count: 64) + ".example.com", "a=b", "a,b", "a#b", "a%b", "a!b", "~root",
    ]

    @Test func hostAcceptsOrdinaryValues() {
        for value in ["server", "my-server.example.com", "pi_4", "192.168.1.10", "127.0.0.1", "::1", "2001:db8::1", "localhost", "a.b.c.d.e"] {
            #expect(ServerInput.host(value) == value, "\(value)")
        }
        #expect(ServerInput.host("  server  ") == "server")
    }

    @Test func hostRejectsInjectionAndOddities() {
        for value in Self.hostile { #expect(ServerInput.host(value) == nil, "kabul edilmemeli: \(value.debugDescription)") }
    }

    @Test func aliasIsAHostWithoutColonsAndShort() {
        #expect(ServerInput.alias("prod-web") == "prod-web")
        #expect(ServerInput.alias("::1") == nil)
        #expect(ServerInput.alias(String(repeating: "a", count: 65)) == nil)
        #expect(ServerInput.alias("*") == nil)
        #expect(ServerInput.alias("!prod") == nil)
    }

    @Test func userRules() {
        #expect(ServerInput.user("ozan") == "ozan")
        #expect(ServerInput.user("deploy.bot_1-a") == "deploy.bot_1-a")
        for value in ["-oProxyCommand=x", "a b", "a;b", "a@b", "", String(repeating: "u", count: 33), "$(id)", "a\nb", "ü"] {
            #expect(ServerInput.user(value) == nil, "\(value.debugDescription)")
        }
    }

    @Test func portRange() {
        #expect(ServerInput.port("22") == 22)
        #expect(ServerInput.port("65535") == 65_535)
        #expect(ServerInput.port(" 80 ") == 80)
        for value in ["0", "65536", "-1", "+1", "1e3", "0x50", "", "123456", "2 2", "٣٣", "22;ls", "99999999999999999999"] {
            #expect(ServerInput.port(value) == nil, "\(value.debugDescription)")
        }
    }

    @Test func displayNameRules() {
        #expect(ServerInput.displayName("Ev sunucusu") == "Ev sunucusu")
        #expect(ServerInput.displayName("Çiğdem NAS") == "Çiğdem NAS")
        for value in ["", "   ", "a\nb", "a\u{0}b", "a\u{202E}b", String(repeating: "x", count: 41)] {
            #expect(ServerInput.displayName(value) == nil, "\(value.debugDescription)")
        }
    }

    @Test func loopbackBindOnly() {
        #expect(ServerInput.loopbackBind("127.0.0.1") == "127.0.0.1")
        #expect(ServerInput.loopbackBind("localhost") == "127.0.0.1")
        #expect(ServerInput.loopbackBind("0.0.0.0") == nil)
        #expect(ServerInput.loopbackBind("192.168.1.2") == nil)
        #expect(ServerInput.loopbackBind("*") == nil)
    }

    @Test func tunnelValidation() {
        #expect(TunnelSpec(kind: .local, listenPort: 8080, targetHost: "db.internal", targetPort: 5432).validated() != nil)
        #expect(TunnelSpec(kind: .local, listenPort: 80, targetHost: "db", targetPort: 5432).validated() == nil, "ayrıcalıklı yerel port")
        #expect(TunnelSpec(kind: .local, listenPort: 8080, targetHost: "-oProxyCommand=x", targetPort: 1).validated() == nil)
        #expect(TunnelSpec(kind: .local, listenPort: 8080, targetHost: "db", targetPort: 0).validated() == nil)
        #expect(TunnelSpec(kind: .local, listenPort: 8080, targetHost: "db", targetPort: 70_000).validated() == nil)
        #expect(TunnelSpec(kind: .remote, listenPort: 80, targetHost: "127.0.0.1", targetPort: 3000).validated() != nil)
        #expect(TunnelSpec(kind: .dynamic, listenPort: 1080).validated() != nil)
        #expect(TunnelSpec(kind: .dynamic, listenPort: 1023).validated() == nil)
        #expect(TunnelSpec(kind: .local, listenPort: 8080, targetHost: "a b", targetPort: 1).validated() == nil)
    }

    @Test func serverValidationRejectsEveryBadField() {
        #expect(ServerConfig(name: "ok", kind: .linux, host: "srv", user: "me", port: 22).validated() != nil)
        for host in Self.hostile { #expect(ServerConfig(name: "x", kind: .linux, host: host).validated() == nil, "\(host.debugDescription)") }
        #expect(ServerConfig(name: "x", kind: .linux, host: "srv", user: "-oFoo=1").validated() == nil)
        #expect(ServerConfig(name: "x", kind: .linux, host: "srv", port: 0).validated() == nil)
        #expect(ServerConfig(name: "x", kind: .linux, host: "srv", port: 70_000).validated() == nil)
        #expect(ServerConfig(name: "a\nb", kind: .linux, host: "srv").validated() == nil)
        let local = ServerConfig(name: "Docker", kind: .localDocker, host: "evil;rm", user: "x", port: 5).validated()
        #expect(local?.host == "" && local?.user == nil && local?.port == nil, "yerel Docker'da ağ alanları temizlenir")
    }

    @Test func storedListDropsBadEntriesCapsAndDeduplicates() {
        let good = Samples.server("A")
        let json = """
        [{"id":"\(good.id.uuidString)","name":"A","kind":"linux","host":"srv.example.invalid","tunnels":[]},
         {"id":"\(good.id.uuidString)","name":"kopya","kind":"linux","host":"srv","tunnels":[]},
         {"id":"\(UUID().uuidString)","name":"kötü","kind":"linux","host":"-oProxyCommand=x","tunnels":[]},
         {"id":"\(UUID().uuidString)","name":"tür","kind":"windows","host":"srv","tunnels":[]},
         {"bozuk":true}]
        """
        let decoded = ServerConfig.decode(json)
        #expect(decoded.servers.count == 1)
        #expect(decoded.dropped == 4)
        let many = (0..<30).map { Samples.server("S\($0)", host: "h\($0)") }
        #expect(ServerConfig.decode(ServerConfig.encode(many)).servers.count == ServerConfig.maxServers)
        #expect(ServerConfig.decode("not json").servers.isEmpty)
        #expect(ServerConfig.decode(String(repeating: "[", count: 300_000)).servers.isEmpty)
        #expect(ServerConfig.decode(nil).servers.isEmpty)
    }

    @Test func storedListHasNoSecretFields() throws {
        let json = ServerConfig.encode([Samples.server()])
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        let keys = Set(try #require(object.first).keys)
        #expect(keys.isSubset(of: ["id", "name", "kind", "host", "user", "port", "tunnels"]))
    }
}

@Suite("ssh argümanları")
struct SSHCommandTests {
    let server = ServerConfig(name: "S", kind: .linux, host: "srv.example.invalid", user: "ozan", port: 2222)
    let environment = SSHEnvironment(controlDirectory: "/tmp/sistem-test-ssh")

    func options(_ arguments: [String]) -> [String] {
        arguments.indices.compactMap { arguments[$0] == "-o" && $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    }

    @Test func scriptCallIsKeyOnlyAndStrict() {
        let arguments = SSHCommand.scriptArguments(server: server, environment: environment)
        let options = options(arguments)
        #expect(options.contains("BatchMode=yes"))
        #expect(options.contains("StrictHostKeyChecking=yes"))
        #expect(options.contains("UpdateHostKeys=no"), "known_hosts'a hiçbir yoldan yazılmaz")
        #expect(options.contains("PasswordAuthentication=no"))
        #expect(options.contains("KbdInteractiveAuthentication=no"))
        #expect(options.contains("PreferredAuthentications=publickey"))
        #expect(options.contains("NumberOfPasswordPrompts=0"))
        #expect(options.contains("ClearAllForwardings=yes"))
        #expect(options.contains("ForwardAgent=no"))
        #expect(options.contains("RemoteCommand=none"))
        let timeout = options.first { $0.hasPrefix("ConnectTimeout=") }.flatMap { Int($0.dropFirst("ConnectTimeout=".count)) }
        #expect((timeout ?? 99) <= 10)
        #expect(!arguments.joined(separator: " ").contains("StrictHostKeyChecking=no"))
        #expect(!arguments.joined(separator: " ").contains("accept-new"))
        #expect(!arguments.contains("-i"), "özel anahtar yolu verilmez")
        let dash = arguments.lastIndex(of: "--")
        #expect(dash != nil && Array(arguments[(dash! + 1)...]) == ["srv.example.invalid", "sh -s"])
        #expect(arguments.contains("-l") && arguments.contains("ozan") && arguments.contains("-p") && arguments.contains("2222"))
    }

    @Test func hostAndUserAreNeverAnOptionEvenIfValidationWereBypassed() {
        let hostile = ServerConfig(name: "x", kind: .linux, host: "-oProxyCommand=touch /tmp/pwn", user: "-oFoo=1", port: 22)
        let arguments = SSHCommand.scriptArguments(server: hostile, environment: environment)
        let dash = arguments.lastIndex(of: "--")!
        #expect(!arguments[..<dash].contains("-oProxyCommand=touch /tmp/pwn"), "host `--` öncesinde olmamalı")
        #expect(arguments[(dash + 1)...].first == "-oProxyCommand=touch /tmp/pwn")
        // The one place the user name appears is as the value of -l, a separate element.
        let l = arguments.firstIndex(of: "-l")!
        #expect(arguments[l + 1] == "-oFoo=1")
    }

    @Test func reachabilityRunsTrue() {
        let arguments = SSHCommand.reachabilityArguments(server: server, environment: environment)
        #expect(arguments.suffix(2) == ["srv.example.invalid", "true"])
        #expect(arguments.contains("BatchMode=yes"))
    }

    @Test func controlPathIsInsideOurDirectoryShortAndQuoted() throws {
        let path = try #require(SSHCommand.controlPath(for: server, in: environment))
        #expect(path.hasPrefix("/tmp/sistem-test-ssh/"))
        #expect(path.utf8.count + 18 <= 104)
        #expect(!path.contains(server.host))
        let arguments = SSHCommand.scriptArguments(server: server, environment: environment)
        #expect(arguments.contains("ControlPath=\"\(path)\""))
        #expect(arguments.contains("ControlMaster=auto"))
        #expect(arguments.contains("ControlPersist=\(SSHCommand.controlPersist)"))
    }

    @Test func tooLongOrOddControlDirectoryFallsBackToNoSharing() {
        let long = SSHEnvironment(controlDirectory: "/" + String(repeating: "d", count: 120))
        #expect(SSHCommand.controlPath(for: server, in: long) == nil)
        #expect(SSHCommand.scriptArguments(server: server, environment: long).contains("ControlMaster=no"))
        #expect(SSHCommand.controlPath(for: server, in: SSHEnvironment(controlDirectory: "/tmp/a%b")) == nil)
        #expect(SSHCommand.controlPath(for: server, in: SSHEnvironment(controlDirectory: "/tmp/a\"b")) == nil)
        #expect(SSHCommand.controlPath(for: server, in: SSHEnvironment()) == nil)
    }

    @Test func tunnelArguments() throws {
        let local = TunnelSpec(kind: .local, listenPort: 8080, targetHost: "db.internal", targetPort: 5432)
        let arguments = try #require(SSHCommand.tunnelArguments(server: server, tunnel: local, environment: environment))
        #expect(arguments.contains("UpdateHostKeys=no") && arguments.contains("StrictHostKeyChecking=yes"))
        #expect(arguments.contains("-N") && arguments.contains("-T"))
        #expect(arguments.contains("ExitOnForwardFailure=yes"))
        #expect(arguments.contains("ControlMaster=no"))
        #expect(arguments.contains("-L") && arguments.contains("127.0.0.1:8080:db.internal:5432"))
        #expect(arguments.last == "srv.example.invalid")
        #expect(arguments[arguments.count - 2] == "--")
        #expect(!arguments.contains("ClearAllForwardings=yes"))

        let remote = try #require(SSHCommand.tunnelArguments(server: server, tunnel: TunnelSpec(kind: .remote, listenPort: 9000, targetHost: "::1", targetPort: 3000), environment: environment))
        #expect(remote.contains("-R") && remote.contains("127.0.0.1:9000:[::1]:3000"))
        let socks = try #require(SSHCommand.tunnelArguments(server: server, tunnel: TunnelSpec(kind: .dynamic, listenPort: 1080), environment: environment))
        #expect(socks.contains("-D") && socks.contains("127.0.0.1:1080"))
        // Never an open listener.
        for list in [arguments, remote, socks] { #expect(!list.contains { $0.hasPrefix("0.0.0.0") || $0.hasPrefix("*:") }) }
        #expect(SSHCommand.tunnelArguments(server: server, tunnel: TunnelSpec(kind: .local, listenPort: 8080, targetHost: "-oX=1", targetPort: 1), environment: environment) == nil)
    }

    @Test func exitMasterAndInteractive() {
        let exit = SSHCommand.exitMasterArguments(server: server, environment: environment)
        #expect(exit?.contains("-O") == true && exit?.contains("exit") == true)
        #expect(SSHCommand.exitMasterArguments(server: server, environment: SSHEnvironment()) == nil)
        #expect(SSHCommand.interactiveArguments(server: server) == ["-l", "ozan", "-p", "2222", "--", "srv.example.invalid"])
    }

    @Test func childEnvironmentIsSmallAndHasNoAskpass() {
        let source = ["HOME": "/Users/x", "SSH_AUTH_SOCK": "/tmp/agent", "SSH_ASKPASS": "/evil", "DISPLAY": ":0", "USER": "x", "SECRET_TOKEN": "s", "SSH_ASKPASS_REQUIRE": "force"]
        let result = SSHCommand.environment(from: source)
        #expect(result["SSH_ASKPASS"] == nil && result["DISPLAY"] == nil && result["SECRET_TOKEN"] == nil && result["SSH_ASKPASS_REQUIRE"] == nil)
        #expect(result["SSH_AUTH_SOCK"] == "/tmp/agent" && result["HOME"] == "/Users/x" && result["LC_ALL"] == "C")
    }

    @Test func scriptsAreFixedTextWithoutPlaceholders() {
        for kind in ServerKind.allCases {
            let script = ServerScripts.script(for: kind)
            #expect(script.hasPrefix("echo 'SISTEM1 ") && script.hasSuffix("echo END"))
            #expect(!script.contains("%@") && !script.contains("\\("))
        }
    }
}
