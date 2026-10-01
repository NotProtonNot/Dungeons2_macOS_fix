import Foundation

public enum FixError: LocalizedError, Equatable {
    case gameRunning
    case steamRunning
    case bottleBusy
    case gameNotFound
    case payloadMissing
    case payloadDamaged
    case registry(String)
    case files(String)

    public var errorDescription: String? {
        switch self {
        case .gameRunning:
            return "Minecraft Dungeons II is running. Quit the game completely, then try again."
        case .steamRunning:
            return "Steam is running in CrossOver. Quit it (Steam menu → Exit), then try again."
        case .bottleBusy:
            return "The bottle is still running. Quit Steam and any other programs in this bottle (or quit CrossOver), then try again."
        case .gameNotFound:
            return "Minecraft Dungeons II wasn't found in this bottle. Install it through Steam in this bottle, or choose its folder."
        case .payloadMissing:
            return "xgameruntime.dll is missing from the app. Download Dungeons II Fixer again."
        case .payloadDamaged:
            return "The bundled xgameruntime.dll doesn't match the expected file. Download Dungeons II Fixer again."
        case .registry(let message), .files(let message):
            return message
        }
    }
}

public enum FixItem: String, CaseIterable, Identifiable, Codable {
    case gamingServices
    case cppRuntime

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .gamingServices: return "Gaming Services fix"
        case .cppRuntime: return "C++ runtime fix"
        }
    }

    public var summary: String {
        switch self {
        case .gamingServices:
            return "Installs NotProton's xgameruntime.dll next to the game, in Win64 and in system32, and sets it to load as native."
        case .cppRuntime:
            return "Sets msvcp140, msvcp140_1, msvcp140_2, vcruntime140 and vcruntime140_1 to native, then builtin."
        }
    }

    /// The problem it solves, in a few words.
    public var fixes: String {
        switch self {
        case .gamingServices: return "The game not starting (Gaming Services missing)."
        case .cppRuntime: return "The C++ runtime error when the game starts."
        }
    }

    /// Needs the game folder, not just the bottle.
    public var needsGame: Bool { self != .cppRuntime }
}

public struct FixStatus: Equatable {
    public enum State: Equatable {
        case applied
        case notApplied
        case needsUpdate
        case unavailable
    }

    public var state: State
    public var detail: String

    public init(_ state: State, _ detail: String) {
        self.state = state
        self.detail = detail
    }
}

/// Applies, checks and removes the Minecraft Dungeons II fixes in one bottle.
public final class FixEngine {
    public static let dllName = "xgameruntime.dll"
    public static let cppRuntimeDLLs = ["msvcp140", "msvcp140_1", "msvcp140_2", "vcruntime140", "vcruntime140_1"]
    public static let gamingServicesOverride = "xgameruntime"

    public let bottle: Bottle
    public let game: GameInstall?
    public let payload: URL
    public let store: ManifestStore
    public var registry: RegistryEditor
    /// SHA-256 of the DLL, recorded in the app when it was built. Nil skips the check (development builds).
    public var expectedHash: String?
    public var isGameRunning: () -> Bool = Processes.isGameRunning
    public var isSteamRunning: () -> Bool = Processes.isSteamRunning
    public var log: (String) -> Void = { _ in } {
        didSet { registry.log = log }
    }

    public init(bottle: Bottle, game: GameInstall?, crossOver: CrossOverInstall?, payload: URL, store: ManifestStore = .standard) {
        self.bottle = bottle
        self.game = game
        self.payload = payload
        self.store = store
        self.registry = RegistryEditor(bottle: bottle, crossOver: crossOver)
    }

    /// The three places the DLL goes.
    public var dllDestinations: [URL] {
        var dirs = [bottle.system32]
        if let game {
            dirs = [game.root, game.shippingDirectory] + dirs
        }
        return dirs.map { $0.appendingPathComponent(Self.dllName) }
    }

    public var manifest: FixManifest? { store.load(for: bottle) }

    // MARK: Status

    public func status(overrides: [String: String]) -> [FixItem: FixStatus] {
        var result: [FixItem: FixStatus] = [:]
        let fm = FileManager.default

        if game == nil {
            result[.gamingServices] = FixStatus(.unavailable, "Needs the game folder")
        } else {
            let payloadHash = FileHash.sha256(of: payload)
            var current = 0, different = 0
            for url in dllDestinations where fm.isFile(url) {
                if FileHash.sha256(of: url) == payloadHash { current += 1 } else { different += 1 }
            }
            let overrideOK = overrides[Self.gamingServicesOverride].map(DllOverrides.normalizedValue) == DllOverrides.native
            let total = dllDestinations.count
            if current == total && overrideOK {
                result[.gamingServices] = FixStatus(.applied, "Installed in all \(total) places")
            } else if different > 0 {
                result[.gamingServices] = FixStatus(.needsUpdate, "A different xgameruntime.dll is installed")
            } else if current == total {
                result[.gamingServices] = FixStatus(.notApplied, "DLL installed, override not set")
            } else {
                result[.gamingServices] = FixStatus(.notApplied, current == 0 ? "Not installed" : "Installed in \(current) of \(total) places")
            }
        }

        let set = Self.cppRuntimeDLLs.filter {
            overrides[$0].map(DllOverrides.normalizedValue) == DllOverrides.nativeThenBuiltin
        }.count
        result[.cppRuntime] = set == Self.cppRuntimeDLLs.count
            ? FixStatus(.applied, "All \(set) overrides set")
            : FixStatus(.notApplied, set == 0 ? "Not set" : "\(set) of \(Self.cppRuntimeDLLs.count) overrides set")
        return result
    }

    // MARK: Apply

    /// Applies the chosen fixes. Everything changed is recorded first so it can be undone,
    /// and a failure halfway leaves a manifest that still undoes what was done.
    /// - Returns: the bottle's DLL overrides after the change.
    @discardableResult
    public func apply(_ items: Set<FixItem>) throws -> [String: String] {
        guard !items.isEmpty else { return registry.storedOverrides() }
        if isGameRunning() { throw FixError.gameRunning }
        if isSteamRunning() { throw FixError.steamRunning }
        if items.contains(where: \.needsGame), game == nil { throw FixError.gameNotFound }
        if items.contains(.gamingServices) { try verifyPayload() }

        var manifest = store.load(for: bottle) ?? FixManifest(bottlePath: bottle.url.path)

        if items.contains(.gamingServices) {
            try installDLL(into: &manifest)
        }

        var changes: DllOverrides.Changes = [:]
        if items.contains(.gamingServices) {
            changes[Self.gamingServicesOverride] = DllOverrides.native
        }
        if items.contains(.cppRuntime) {
            for name in Self.cppRuntimeDLLs { changes[name] = DllOverrides.nativeThenBuiltin }
        }
        var overrides = registry.storedOverrides()
        if !changes.isEmpty {
            for name in changes.keys where manifest.previousOverrides[name] == nil {
                manifest.previousOverrides[name] = .some(overrides[DllOverrides.normalizedName(name)])
            }
            try persist(&manifest)
            overrides = try registry.apply(changes)
            log("DLL overrides set: \(changes.keys.sorted().joined(separator: ", ")).")
        }

        try persist(&manifest)
        log("Done.")
        return overrides
    }

    private func persist(_ manifest: inout FixManifest) throws {
        manifest.updated = Date()
        do {
            try store.save(manifest, for: bottle)
        } catch {
            throw FixError.files("Couldn't save the undo record: \(error.localizedDescription)")
        }
    }

    private func verifyPayload() throws {
        guard FileManager.default.isFile(payload) else { throw FixError.payloadMissing }
        if let expectedHash, FileHash.sha256(of: payload) != expectedHash { throw FixError.payloadDamaged }
    }

    private func installDLL(into manifest: inout FixManifest) throws {
        let fm = FileManager.default
        let payloadHash = FileHash.sha256(of: payload)
        let backups = store.backupDirectory(for: bottle)

        for (index, destination) in dllDestinations.enumerated() {
            let folder = destination.deletingLastPathComponent()
            guard fm.isDirectory(folder) else {
                throw FixError.files("The folder \(folder.abbreviatedPath) doesn't exist.")
            }
            let alreadyTracked = manifest.installedFiles.contains { $0.path == destination.path }
            if !alreadyTracked {
                var entry = FixManifest.InstalledFile(path: destination.path, backupPath: nil)
                // Keep whatever was there before (Wine's own stub, or an older copy) so it can be restored.
                if fm.isFile(destination), FileHash.sha256(of: destination) != payloadHash {
                    let backup = backups.appendingPathComponent("\(index)-\(Self.dllName)")
                    do {
                        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
                        try? fm.removeItem(at: backup)
                        try fm.copyItem(at: destination, to: backup)
                    } catch {
                        throw FixError.files("Couldn't back up \(destination.abbreviatedPath): \(error.localizedDescription)")
                    }
                    entry.backupPath = backup.path
                }
                manifest.installedFiles.append(entry)
                try persist(&manifest)
            }
            do {
                try fm.copyReplacing(payload, to: destination)
            } catch {
                throw FixError.files("Couldn't copy the DLL to \(folder.abbreviatedPath): \(error.localizedDescription)")
            }
            log("Copied \(Self.dllName) to \(folder.abbreviatedPath)")
        }
    }

    // MARK: Undo

    /// Puts back everything recorded in the manifest.
    @discardableResult
    public func undo() throws -> [String: String] {
        guard let manifest = store.load(for: bottle) else { return registry.storedOverrides() }
        // Steam may stay open here: removing only restores files and overrides.
        if isGameRunning() { throw FixError.gameRunning }
        let fm = FileManager.default

        for file in manifest.installedFiles {
            let destination = URL(fileURLWithPath: file.path)
            do {
                if let backupPath = file.backupPath, fm.isFile(URL(fileURLWithPath: backupPath)) {
                    try fm.copyReplacing(URL(fileURLWithPath: backupPath), to: destination)
                    log("Restored the original \(Self.dllName) in \(destination.deletingLastPathComponent().abbreviatedPath)")
                } else if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                    log("Removed \(Self.dllName) from \(destination.deletingLastPathComponent().abbreviatedPath)")
                }
            } catch {
                throw FixError.files("Couldn't restore \(destination.abbreviatedPath): \(error.localizedDescription)")
            }
        }

        var overrides = registry.storedOverrides()
        if !manifest.previousOverrides.isEmpty {
            overrides = try registry.apply(manifest.previousOverrides)
            log("Restored the previous DLL overrides.")
        }

        // Earlier versions could set GamingRepair aside; put it back for those bottles.
        if let path = manifest.gamingRepairPath {
            let original = URL(fileURLWithPath: path, isDirectory: true)
            let setAside = original.deletingLastPathComponent().appendingPathComponent("GamingRepair.disabled", isDirectory: true)
            if fm.isDirectory(setAside), !fm.fileExists(atPath: original.path) {
                do {
                    try fm.moveItem(at: setAside, to: original)
                    log("Put GamingRepair back.")
                } catch {
                    throw FixError.files("Couldn't put GamingRepair back: \(error.localizedDescription)")
                }
            }
        }

        store.delete(for: bottle)
        log("All fixes removed.")
        return overrides
    }
}
