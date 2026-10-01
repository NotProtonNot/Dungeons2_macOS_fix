import Foundation

/// Reads and writes a bottle's DLL overrides.
public struct RegistryEditor {
    public let bottle: Bottle
    public let crossOver: CrossOverInstall?
    public var isWineServerRunning: () -> Bool = Processes.isWineServerRunning
    public var log: (String) -> Void = { _ in }

    public init(bottle: Bottle, crossOver: CrossOverInstall?) {
        self.bottle = bottle
        self.crossOver = crossOver
    }

    /// What user.reg says. While the bottle is running this can lag a few seconds behind Wine.
    public func storedOverrides() -> [String: String] {
        guard let text = try? String(contentsOf: bottle.userRegistry, encoding: .utf8) else { return [:] }
        return DllOverrides.read(userReg: text)
    }

    /// Applies the changes and returns the overrides as Wine now reports them.
    ///
    /// The normal route is CrossOver's own Wine (`regedit /S`), exactly like winecfg would do it,
    /// which is safe even while the bottle is running. If that is unavailable or fails, user.reg is
    /// edited directly, but only once Wine has let go of it.
    @discardableResult
    public func apply(_ changes: DllOverrides.Changes) throws -> [String: String] {
        guard !changes.isEmpty else { return storedOverrides() }
        if let crossOver, crossOver.hasWine {
            if let result = applyWithWine(changes, crossOver: crossOver), Self.matches(result, changes) {
                return result
            }
            log("CrossOver didn't confirm the change, editing the registry file directly instead.")
        } else {
            log("CrossOver's Wine wasn't found, editing the registry file directly.")
        }
        try applyToFile(changes)
        let result = storedOverrides()
        guard Self.matches(result, changes) else {
            throw FixError.registry("The DLL overrides could not be saved in the bottle's registry.")
        }
        return result
    }

    static func matches(_ current: [String: String], _ changes: DllOverrides.Changes) -> Bool {
        changes.allSatisfy { name, wanted in
            let have = current[DllOverrides.normalizedName(name)]
            guard let wanted else { return have == nil }
            return have.map(DllOverrides.normalizedValue) == DllOverrides.normalizedValue(wanted)
        }
    }

    private func wine(_ crossOver: CrossOverInstall, _ arguments: [String]) -> CommandResult {
        let environment = [
            "CX_BOTTLE": bottle.name,
            // Lets CrossOver find bottles kept outside its default folder.
            "CX_BOTTLE_PATH": bottle.url.deletingLastPathComponent().path,
            "WINEDEBUG": "-all",
        ]
        return Shell.run(crossOver.wineBinary, ["--bottle", bottle.name] + arguments, environment: environment, timeout: 120)
    }

    private func applyWithWine(_ changes: DllOverrides.Changes, crossOver: CrossOverInstall) -> [String: String]? {
        let fm = FileManager.default
        let regFile = bottle.tempDirectory.appendingPathComponent("dungeons-fixer-\(UUID().uuidString.prefix(8)).reg")
        do {
            try fm.createDirectory(at: bottle.tempDirectory, withIntermediateDirectories: true)
            try DllOverrides.regFile(for: changes).write(to: regFile)
        } catch {
            log("Couldn't write the registry file: \(error.localizedDescription)")
            return nil
        }
        defer { try? fm.removeItem(at: regFile) }

        log("Updating DLL overrides with \(crossOver.displayName)…")
        let windowsPath = "C:\\windows\\temp\\" + regFile.lastPathComponent
        let imported = wine(crossOver, ["regedit", "/S", windowsPath])
        if !imported.succeeded {
            log(imported.timedOut ? "regedit timed out." : "regedit failed (\(imported.status)): \(imported.output.suffix(300))")
            return nil
        }
        let query = wine(crossOver, ["reg", "query", #"HKEY_CURRENT_USER\Software\Wine\DllOverrides"#])
        guard query.succeeded else {
            log("reg query failed (\(query.status)): \(query.output.suffix(300))")
            return nil
        }
        return DllOverrides.parseRegQuery(query.output)
    }

    private func applyToFile(_ changes: DllOverrides.Changes) throws {
        // Wine keeps the registry in memory and writes it back when it exits,
        // which would undo a direct edit. Give it a moment to shut down on its own.
        var waited = 0.0
        while isWineServerRunning() {
            guard waited < 15 else { throw FixError.bottleBusy }
            Thread.sleep(forTimeInterval: 0.5)
            waited += 0.5
        }
        let fm = FileManager.default
        guard let text = try? String(contentsOf: bottle.userRegistry, encoding: .utf8) else {
            throw FixError.registry("This bottle has no user.reg. Open it in CrossOver once, then try again.")
        }
        let backup = bottle.url.appendingPathComponent("user.reg.dungeons-fixer-backup")
        if !fm.fileExists(atPath: backup.path) {
            try? fm.copyItem(at: bottle.userRegistry, to: backup)
        }
        let updated = DllOverrides.updating(userReg: text, with: changes)
        do {
            try updated.write(to: bottle.userRegistry, atomically: true, encoding: .utf8)
        } catch {
            throw FixError.registry("Couldn't save the bottle's registry: \(error.localizedDescription)")
        }
        log("Saved DLL overrides to user.reg.")
    }
}
