import Foundation

/// Disk usage as reported by `container system df`, plus Space's own volumes.
public struct DiskUsage: Codable, Sendable {
    public struct Bucket: Codable, Sendable {
        public let total: Int
        public let active: Int
        public let sizeInBytes: UInt64
        public let reclaimable: UInt64
    }
    public struct VolumeUsage: Codable, Sendable, Hashable {
        public let name: String
        public let service: String
        /// Bytes actually used on disk (volumes are sparse images).
        public let bytes: UInt64
    }
    public let images: Bucket
    public let containers: Bucket
    public let volumes: Bucket
    public let spaceVolumes: [VolumeUsage]
}

public struct ReclaimResult: Codable, Sendable {
    public let freedBytes: UInt64
    public let removed: [String]
}

public struct ReclaimRequest: Codable, Sendable {
    public var includeData: Bool
    public init(includeData: Bool) { self.includeData = includeData }
}

public struct ImageSetting: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let defaultImage: String
    public let image: String
    public let overridden: Bool
    public let hidden: Bool
}

public struct ImageOverrideRequest: Codable, Sendable {
    /// Empty or nil resets to the recipe's image.
    public var image: String?
    public init(image: String?) { self.image = image }
}

public struct UpdateResult: Codable, Sendable {
    public let updated: [String]
    public let failed: [String: String]
}

extension ServiceManager {
    // MARK: Images

    public func imageSettings() -> [ImageSetting] {
        let overrides = SpaceState.load().images
        return store.all.map { r in
            ImageSetting(id: r.id, name: r.name, defaultImage: r.image, image: overrides[r.id] ?? r.image,
                         overridden: overrides[r.id] != nil, hidden: r.hidden ?? false)
        }
    }

    /// Sets (or clears) the image for a service. Takes effect on the next update/recreate.
    public func setImage(_ id: String, _ image: String?) throws {
        _ = try recipe(id)
        var state = SpaceState.load()
        let trimmed = image?.trimmingCharacters(in: .whitespaces) ?? ""
        if trimmed.isEmpty || trimmed == (try? defaultImage(id)) { state.images[id] = nil } else { state.images[id] = trimmed }
        try state.save()
    }

    /// Pulls the latest image for every installed service (stack parts are handled by their parent).
    public func updateAll() async throws -> UpdateResult {
        var updated: [String] = [], failed: [String: String] = [:]
        for s in try await status() where s.state != .notCreated && !s.hidden {
            do { try await pullLatest(s.id); updated.append(s.id) }
            catch { failed[s.id] = String(describing: error) }
        }
        return UpdateResult(updated: updated, failed: failed)
    }

    // MARK: Disk

    public func diskUsage() async throws -> DiskUsage {
        struct DF: Decodable { let images, containers, volumes: DiskUsage.Bucket }
        let df = try JSONDecoder().decode(DF.self, from: try await cli.diskUsageJSON())
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/com.apple.container/volumes")
        var vols: [DiskUsage.VolumeUsage] = []
        for r in recipes {
            for v in r.volumes ?? [] {
                let name = r.volumeName(v)
                let img = root.appending(path: "\(name)/volume.img")
                let bytes = (try? img.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize).flatMap { $0 } ?? 0
                if bytes > 0 { vols.append(.init(name: name, service: r.id, bytes: UInt64(bytes))) }
            }
        }
        return DiskUsage(images: df.images, containers: df.containers, volumes: df.volumes, spaceVolumes: vols)
    }

    /// Frees space used by Space without touching data: deletes stopped Space containers (recreated on next
    /// start), Space and helper images no container uses (re-downloaded when needed), and dangling images.
    /// With `includeData`, also deletes the data volumes of services that aren't running.
    public func reclaim(includeData: Bool = false) async throws -> ReclaimResult {
        let before = try await diskUsage()
        var removed: [String] = []

        let running = Set(try await cli.list().filter(\.isRunning).map(\.id))
        for r in recipes where !running.contains(r.containerName) {
            if try await cli.list().contains(where: { $0.id == r.containerName }) {
                try await cli.delete(r.containerName)
                removed.append("container \(r.containerName)")
            }
            if includeData {
                for v in r.volumes ?? [] {
                    if (try? await cli.deleteVolume(r.volumeName(v))) != nil { removed.append("volume \(r.volumeName(v))") }
                }
            }
        }

        // Images Space knows about: service images (current and overridden) and helper images used by actions.
        var known = Set<String>()
        for r in store.all + recipes {
            known.insert(Self.normalize(r.image))
            for a in (r.actions ?? [:]).values { if let img = a.image { known.insert(Self.normalize(img)) } }
        }
        // Keep images used by any remaining container (Space's or not).
        let inUse = Set(try await cli.list().map { Self.normalize($0.image) })
        let unused = try await cli.images().filter { known.contains(Self.normalize($0.name)) && !inUse.contains(Self.normalize($0.name)) }
        if !unused.isEmpty {
            try await cli.deleteImages(unused.map(\.name))
            removed += unused.map { "image \($0.name)" }
        }
        try? await cli.pruneDanglingImages()

        let after = try await diskUsage()
        let total = { (d: DiskUsage) in d.images.sizeInBytes + d.containers.sizeInBytes + d.spaceVolumes.reduce(0) { $0 + $1.bytes } }
        return ReclaimResult(freedBytes: total(before) > total(after) ? total(before) - total(after) : 0, removed: removed)
    }

    /// `redis:latest` → `docker.io/library/redis:latest`, `a/b` → `docker.io/a/b:latest`.
    static func normalize(_ ref: String) -> String {
        var r = ref
        if !r.contains(":") || r.split(separator: "/").last?.contains(":") == false { r += ":latest" }
        let parts = r.split(separator: "/")
        if parts.count == 1 { return "docker.io/library/\(r)" }
        if !(parts[0].contains(".") || parts[0].contains(":") || parts[0] == "localhost") { return "docker.io/\(r)" }
        return r
    }
}
