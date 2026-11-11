import Foundation

/// Subset of Tailscale's ipnstate.Status JSON that Space cares about.
public struct TailnetStatus: Codable, Sendable {
    public struct Device: Codable, Sendable, Hashable {
        public let hostName: String
        /// MagicDNS name without trailing dot, e.g. `space-macmini.tail1234.ts.net`.
        public let dnsName: String
        public let ips: [String]
        public let os: String
        public let online: Bool
        /// Short tailnet name, e.g. `space-macmini`.
        public var name: String { dnsName.split(separator: ".").first.map(String.init) ?? hostName }
        public var isSpace: Bool { name.hasPrefix("space-") }
    }

    /// `Running`, `NeedsLogin`, `NeedsMachineAuth`, `Starting`, `NoState`, or `Stopped` (node not started).
    public let state: String
    public let tailnet: String?
    public let authURL: String?
    public let me: Device?
    public let peers: [Device]

    public var loggedIn: Bool { state == "Running" }

    public static let stopped = TailnetStatus(state: "Stopped", tailnet: nil, authURL: nil, me: nil, peers: [])

    private struct Raw: Decodable {
        struct Peer: Decodable {
            let HostName: String?
            let DNSName: String?
            let TailscaleIPs: [String]?
            let OS: String?
            let Online: Bool?
            var device: Device {
                Device(hostName: HostName ?? "", dnsName: (DNSName ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ".")),
                       ips: TailscaleIPs ?? [], os: OS ?? "", online: Online ?? false)
            }
        }
        struct Tailnet: Decodable { let Name: String? }
        let BackendState: String
        let AuthURL: String?
        let `Self`: Peer?
        let Peer: [String: Peer]?
        let CurrentTailnet: Tailnet?
    }

    public static func parse(_ data: Data) -> TailnetStatus? {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }
        return TailnetStatus(
            state: raw.BackendState,
            tailnet: raw.CurrentTailnet?.Name,
            authURL: raw.AuthURL.flatMap { $0.isEmpty ? nil : $0 },
            me: raw.Self?.device,
            peers: (raw.Peer ?? [:]).values.map(\.device).sorted { $0.name < $1.name }
        )
    }
}
