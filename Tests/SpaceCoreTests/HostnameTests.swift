import Testing
@testable import SpaceCore
@testable import SpaceNet

@Suite struct HostnameTests {
    @Test func caddyfileServesHTTPAndHTTPSPerSite() {
        let cfg = Hostnames.caddyConfig(sites: [.init(name: "api.acme", port: 3101), .init(name: "acme", port: 3100)])
        #expect(cfg.contains("local_certs"))
        #expect(cfg.contains("admin localhost:20190"))
        #expect(cfg.contains("http://acme.space.test, https://acme.space.test {\n\treverse_proxy localhost:3100\n}"))
        #expect(cfg.contains("http://api.acme.space.test, https://api.acme.space.test {\n\treverse_proxy localhost:3101\n}"))
        #expect(cfg.range(of: "acme.space.test,")!.lowerBound < cfg.range(of: "api.acme.space.test,")!.lowerBound)
    }

    @Test func dnsmasqOnlyAnswersSpaceTest() {
        let cfg = Hostnames.dnsmasqConfig()
        #expect(cfg.contains("port=53535"))
        #expect(cfg.contains("listen-address=127.0.0.1"))
        #expect(cfg.contains("no-resolv"))
        #expect(cfg.contains("address=/space.test/127.0.0.1"))
    }

    @Test func siteNamesAreValidated() {
        for ok in ["acme", "api.acme", "my-app2"] { #expect(ok.wholeMatch(of: Hostnames.namePattern) != nil, "\(ok)") }
        for bad in ["-acme", "acme-", "Acme_1", "a..b", "", "acme/../x"] { #expect(bad.wholeMatch(of: Hostnames.namePattern) == nil, "\(bad)") }
    }
}
