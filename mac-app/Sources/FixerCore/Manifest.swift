import Foundation

/// Everything the fixer changed in one bottle, so "Remove Fixes" can put it all back.
public struct FixManifest: Codable, Equatable {
    public struct InstalledFile: Codable, Equatable {
        public var path: String
        /// A copy of the file that was there before, if any.
        public var backupPath: String?
    }

    public var bottlePath: String
    public var installedFiles: [InstalledFile] = []
    /// Override values from before the first change; nil means the override didn't exist.
    public var previousOverrides: [String: String?] = [:]
    /// Where GamingRepair was before an earlier version set it aside. Only read by undo now.
    public var gamingRepairPath: String?
    public var updated = Date()

    public init(bottlePath: String) {
        self.bottlePath = bottlePath
    }

    public var isEmpty: Bool {
        installedFiles.isEmpty && previousOverrides.isEmpty && gamingRepairPath == nil
    }
}

public struct ManifestStore {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// ~/Library/Application Support/Dungeons II Fixer
    public static var standard: ManifestStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ManifestStore(directory: support.appendingPathComponent("Dungeons II Fixer", isDirectory: true))
    }

    private func key(for bottle: Bottle) -> String {
        let safeName = bottle.name.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let hash = String(FileHash.sha256(Data(bottle.url.path.utf8)).prefix(10))
        return String(safeName) + "-" + hash
    }

    private func manifestURL(for bottle: Bottle) -> URL {
        directory.appendingPathComponent("Bottles/\(key(for: bottle)).json")
    }

    public func backupDirectory(for bottle: Bottle) -> URL {
        directory.appendingPathComponent("Backups/\(key(for: bottle))", isDirectory: true)
    }

    public func load(for bottle: Bottle) -> FixManifest? {
        guard let data = try? Data(contentsOf: manifestURL(for: bottle)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(FixManifest.self, from: data)
    }

    public func save(_ manifest: FixManifest, for bottle: Bottle) throws {
        let url = manifestURL(for: bottle)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    public func delete(for bottle: Bottle) {
        try? FileManager.default.removeItem(at: manifestURL(for: bottle))
        try? FileManager.default.removeItem(at: backupDirectory(for: bottle))
    }
}
