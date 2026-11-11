import Foundation
import Testing
@testable import SpaceCore
@testable import SpaceNet

@Suite struct TailscaleTests {
    @Test func parsesRunningStatus() throws {
        let json = """
        {"BackendState":"Running","AuthURL":"",
         "Self":{"HostName":"Arish-MBP","DNSName":"arish-mbp.tail1234.ts.net.","TailscaleIPs":["100.64.0.1","fd7a::1"],"OS":"macOS","Online":true},
         "Peer":{"nodekey:abc":{"HostName":"macmini","DNSName":"macmini.tail1234.ts.net.","TailscaleIPs":["100.64.0.2"],"OS":"macOS","Online":false}},
         "CurrentTailnet":{"Name":"me@example.com","MagicDNSSuffix":"tail1234.ts.net"}}
        """
        let s = try #require(TailnetStatus.parse(Data(json.utf8)))
        #expect(s.loggedIn)
        #expect(s.me?.name == "arish-mbp")
        #expect(s.me?.dnsName == "arish-mbp.tail1234.ts.net")
        #expect(s.peers.map(\.name) == ["macmini"])
        #expect(s.peers.first?.online == false)
        #expect(s.authURL == nil)
    }

    @Test func parsesLoggedOutStatus() throws {
        let s = try #require(TailnetStatus.parse(Data(#"{"BackendState":"NeedsLogin","AuthURL":"https://login.tailscale.com/a/x","Self":null,"Peer":null}"#.utf8)))
        #expect(!s.loggedIn)
        #expect(s.authURL == "https://login.tailscale.com/a/x")
        #expect(s.peers.isEmpty)
    }

    @Test func spacePeersAreRecognised() throws {
        let json = #"{"BackendState":"Running","Peer":{"a":{"DNSName":"space-macmini.t.ts.net.","Online":true},"b":{"DNSName":"iphone.t.ts.net.","Online":true}}}"#
        let s = try #require(TailnetStatus.parse(Data(json.utf8)))
        #expect(s.peers.filter(\.isSpace).map(\.name) == ["space-macmini"])
    }

    @Test func mountRewritesConnectionPorts() {
        let out = NetworkManager.rewrite(
            ["url": "postgres://space:space@localhost:5432/postgres"],
            ports: ["pg": .init(remote: 5432, local: 15000)])
        #expect(out["url"] == "postgres://space:space@localhost:15000/postgres")
    }
}
