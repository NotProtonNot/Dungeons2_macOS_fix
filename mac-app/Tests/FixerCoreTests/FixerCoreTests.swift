import XCTest
@testable import FixerCore

final class VDFTests: XCTestCase {
    func testLibraryFolders() throws {
        let text = #"""
        "libraryfolders"
        {
            "0"
            {
                "path"		"C:\\Program Files (x86)\\Steam"
                "apps" { "228980" "1" }
            }
            // a comment
            "1"
            {
                "path"		"D:\\Games\\Steam Library"
            }
        }
        """#
        let pairs = try VDF.parse(text)
        XCTAssertEqual(VDFValue.object(pairs).strings(forKey: "path"),
                       [#"C:\Program Files (x86)\Steam"#, #"D:\Games\Steam Library"#])
    }

    func testAppManifest() throws {
        let text = "\"AppState\"\n{\n\t\"appid\"\t\t\"1912410\"\n\t\"installdir\"\t\t\"Minecraft Dungeons II\"\n}\n"
        let pairs = try VDF.parse(text)
        XCTAssertEqual(pairs.value(for: "appstate")?["InstallDir"]?.string, "Minecraft Dungeons II")
    }

    func testMalformed() {
        XCTAssertThrowsError(try VDF.parse("\"a\" { \"b\" \"c\""))
        XCTAssertThrowsError(try VDF.parse("\"unterminated"))
    }
}

final class DllOverridesTests: XCTestCase {
    let userReg = """
    WINE REGISTRY Version 2
    ;; All keys relative to \\\\User\\\\S-1-5-21-0-0-0-1000

    #arch=win64

    [Software\\\\Wine\\\\DllOverrides] 1727700000
    #time=1db1234567890ab
    "*d3dcompiler_47"="native,builtin"
    "msvcp140"="builtin"

    [Software\\\\Wine\\\\Fonts] 1727700000
    #time=1db1234567890ab
    "Codepages"="1252,437"

    """

    func testRead() {
        let overrides = DllOverrides.read(userReg: userReg)
        XCTAssertEqual(overrides, ["d3dcompiler_47": "native,builtin", "msvcp140": "builtin"])
    }

    func testUpdateExistingSection() {
        let updated = DllOverrides.updating(userReg: userReg, with: [
            "msvcp140": "native,builtin",
            "xgameruntime": "native",
            "d3dcompiler_47": nil,
        ])
        XCTAssertEqual(DllOverrides.read(userReg: updated), [
            "msvcp140": "native,builtin",
            "xgameruntime": "native",
        ])
        // Other sections are untouched and still separated by a blank line.
        XCTAssertTrue(updated.contains("\"xgameruntime\"=\"native\"\n\n[Software\\\\Wine\\\\Fonts]"))
        XCTAssertTrue(updated.contains("\"Codepages\"=\"1252,437\""))
        XCTAssertTrue(updated.contains("#time=1db1234567890ab\n\"msvcp140\""))
    }

    func testCreateSection() {
        let base = "WINE REGISTRY Version 2\n\n[Software\\\\Wine] 1\n\"Version\"=\"win10\"\n"
        let updated = DllOverrides.updating(userReg: base, with: ["vcruntime140": "native,builtin"],
                                            now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(DllOverrides.read(userReg: updated), ["vcruntime140": "native,builtin"])
        XCTAssertTrue(updated.contains("[Software\\\\Wine\\\\DllOverrides] 1700000000\n#time="))
        XCTAssertTrue(updated.hasPrefix(base))
    }

    func testRegFile() throws {
        let data = DllOverrides.regFile(for: ["xgameruntime": "native", "old": nil])
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xFE])
        let text = try XCTUnwrap(String(data: data.dropFirst(2), encoding: .utf16LittleEndian))
        XCTAssertTrue(text.hasPrefix("Windows Registry Editor Version 5.00\r\n"))
        XCTAssertTrue(text.contains("[HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides]\r\n\"old\"=-\r\n\"xgameruntime\"=\"native\"\r\n"))
    }

    func testParseRegQuery() {
        let output = """

        HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides
            *d3dcompiler_47    REG_SZ    native,builtin
            msvcp140    REG_SZ    native,builtin
            empty    REG_SZ

        """
        XCTAssertEqual(DllOverrides.parseRegQuery(output), [
            "d3dcompiler_47": "native,builtin",
            "msvcp140": "native,builtin",
            "empty": "",
        ])
    }

    func testMatches() {
        XCTAssertTrue(RegistryEditor.matches(["msvcp140": "Native, Builtin"], ["MSVCP140": "native,builtin", "gone": nil]))
        XCTAssertFalse(RegistryEditor.matches(["msvcp140": "builtin"], ["msvcp140": "native,builtin"]))
        XCTAssertFalse(RegistryEditor.matches(["gone": "native"], ["gone": nil]))
    }
}

/// Builds a throwaway bottle with Steam and the game in it.
final class Sandbox {
    let root: URL
    let bottle: Bottle
    let gameRoot: URL
    let payload: URL
    let store: ManifestStore

    init(withGame: Bool = true, secondLibrary: Bool = false) throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("DungeonsFixerTests-\(UUID().uuidString)", isDirectory: true)
        let bottleURL = root.appendingPathComponent("Bottles/Steam", isDirectory: true)
        bottle = Bottle(url: bottleURL)
        try fm.createDirectory(at: bottle.system32, withIntermediateDirectories: true)
        try fm.createDirectory(at: bottle.driveC.appendingPathComponent("windows/syswow64"), withIntermediateDirectories: true)
        try "[Bottle]\n".write(to: bottleURL.appendingPathComponent("cxbottle.conf"), atomically: true, encoding: .utf8)
        try "WINE REGISTRY Version 2\n\n".write(to: bottle.userRegistry, atomically: true, encoding: .utf8)
        try fm.createDirectory(at: bottleURL.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: bottleURL.appendingPathComponent("dosdevices/c:").path, withDestinationPath: "../drive_c")

        let steam = bottle.driveC.appendingPathComponent("Program Files (x86)/Steam", isDirectory: true)
        var library = steam
        if secondLibrary {
            let dDrive = root.appendingPathComponent("ExternalDisk", isDirectory: true)
            try fm.createDirectory(at: dDrive, withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: bottleURL.appendingPathComponent("dosdevices/d:").path, withDestinationPath: dDrive.path)
            library = dDrive.appendingPathComponent("Games/SteamLibrary", isDirectory: true)
        }
        try fm.createDirectory(at: steam.appendingPathComponent("steamapps"), withIntermediateDirectories: true)
        try """
        "libraryfolders"
        {
            "0" { "path" "C:\\\\Program Files (x86)\\\\Steam" }
            "1" { "path" "D:\\\\Games\\\\SteamLibrary" }
        }
        """.write(to: steam.appendingPathComponent("steamapps/libraryfolders.vdf"), atomically: true, encoding: .utf8)

        gameRoot = library.appendingPathComponent("steamapps/common/Minecraft Dungeons II", isDirectory: true)
        if withGame {
            let game = GameInstall(root: gameRoot)
            try fm.createDirectory(at: game.shippingDirectory, withIntermediateDirectories: true)
            try fm.createDirectory(at: game.gamingRepairDirectory, withIntermediateDirectories: true)
            try Data("exe".utf8).write(to: game.launcher)
            try Data("exe".utf8).write(to: game.shippingExecutable)
            try Data("repair".utf8).write(to: game.gamingRepairDirectory.appendingPathComponent("GamingRepair.exe"))
            try """
            "AppState" { "appid" "1912410" "installdir" "Minecraft Dungeons II" }
            """.write(to: library.appendingPathComponent("steamapps/appmanifest_1912410.acf"), atomically: true, encoding: .utf8)
        }

        payload = root.appendingPathComponent("xgameruntime.dll")
        try Data("fake stand-in dll".utf8).write(to: payload)
        store = ManifestStore(directory: root.appendingPathComponent("Support", isDirectory: true))
    }

    func engine(gameRunning: Bool = false, steamRunning: Bool = false) -> FixEngine {
        let engine = FixEngine(bottle: bottle, game: GameLocator.locate(in: bottle), crossOver: nil, payload: payload, store: store)
        engine.expectedHash = FileHash.sha256(of: payload)!
        engine.isGameRunning = { gameRunning }
        engine.isSteamRunning = { steamRunning }
        engine.registry.isWineServerRunning = { false }
        return engine
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

final class LocatorTests: XCTestCase {
    func testFindsBottleAndGame() throws {
        let box = try Sandbox()
        XCTAssertEqual(BottleLocator.bottles(in: [box.bottle.url.deletingLastPathComponent()]).map(\.name), ["Steam"])
        XCTAssertTrue(box.bottle.is64Bit)
        let game = try XCTUnwrap(GameLocator.locate(in: box.bottle))
        XCTAssertEqual(game.root.resolvingSymlinksInPath().path, box.gameRoot.resolvingSymlinksInPath().path)
    }

    func testFindsGameInSecondLibrary() throws {
        let box = try Sandbox(secondLibrary: true)
        let game = try XCTUnwrap(GameLocator.locate(in: box.bottle))
        XCTAssertEqual(game.root.resolvingSymlinksInPath().path, box.gameRoot.resolvingSymlinksInPath().path)
    }

    func testNoGame() throws {
        let box = try Sandbox(withGame: false)
        XCTAssertNil(GameLocator.locate(in: box.bottle))
    }

    func testValidateNearby() throws {
        let box = try Sandbox()
        let game = GameInstall(root: box.gameRoot)
        XCTAssertNotNil(GameLocator.validate(game.shippingDirectory, searchNearby: true))
        XCTAssertNotNil(GameLocator.validate(box.gameRoot.deletingLastPathComponent(), searchNearby: true))
        XCTAssertNil(GameLocator.validate(game.shippingDirectory))
    }

    func testWindowsPaths() throws {
        let box = try Sandbox()
        XCTAssertEqual(box.bottle.unixURL(forWindowsPath: #"C:\windows\system32"#)?.path, box.bottle.system32.path)
        XCTAssertNil(box.bottle.unixURL(forWindowsPath: #"Q:\nowhere"#))
        XCTAssertNil(box.bottle.unixURL(forWindowsPath: "relative"))
    }

    func testPreferenceFolders() throws {
        let box = try Sandbox()
        let bottles = box.bottle.url.deletingLastPathComponent()
        let found = BottleLocator.directories(fromPreferences: [
            "BottleDir": bottles.path,
            "Recent": ["/nonexistent", box.root.path],
            "Number": 3,
        ])
        XCTAssertEqual(found.map { $0.resolvingSymlinksInPath().path }, [bottles.resolvingSymlinksInPath().path])
    }

    func testCrossOverDetection() throws {
        let fm = FileManager.default
        let apps = fm.temporaryDirectory.appendingPathComponent("Apps-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: apps) }
        func makeApp(_ name: String, id: String, version: String) throws {
            let contents = apps.appendingPathComponent("\(name).app/Contents", isDirectory: true)
            try fm.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
        }
        try makeApp("CrossOver", id: CrossOverLocator.bundleIdentifier, version: "25.1.1")
        try makeApp("CrossOver 24", id: CrossOverLocator.bundleIdentifier, version: "24.0.7")
        try makeApp("CrossOver 25.0", id: CrossOverLocator.bundleIdentifier, version: "25.0")
        try makeApp("Safari", id: "com.apple.Safari", version: "18")

        // Only apps directly in the searched folders count, not copies tucked away elsewhere.
        try makeApp("Backups/CrossOver", id: CrossOverLocator.bundleIdentifier, version: "26.0")

        let found = CrossOverLocator.find(searchDirectories: [apps])
        XCTAssertEqual(found.map(\.version), ["25.1.1", "25.0", "24.0.7"])
        XCTAssertEqual(found.map(\.displayName), ["CrossOver 25.1.1", "CrossOver 25.0", "CrossOver 24.0.7"])
    }
}

final class FixEngineTests: XCTestCase {
    func testApplyAndUndo() throws {
        let box = try Sandbox()
        let engine = box.engine()
        let game = try XCTUnwrap(engine.game)

        // Wine ships its own placeholder in system32; it must come back on undo.
        let system32DLL = box.bottle.system32.appendingPathComponent("xgameruntime.dll")
        try Data("wine builtin".utf8).write(to: system32DLL)
        // An override the user set earlier must survive a round trip.
        try engine.registry.apply(["msvcp140": "builtin"])

        var status = engine.status(overrides: engine.registry.storedOverrides())
        XCTAssertEqual(status[.gamingServices]?.state, .needsUpdate)
        XCTAssertEqual(status[.cppRuntime]?.state, .notApplied)

        let overrides = try engine.apply(Set(FixItem.allCases))
        XCTAssertEqual(overrides["xgameruntime"], "native")

        status = engine.status(overrides: engine.registry.storedOverrides())
        XCTAssertEqual(status[.gamingServices]?.state, .applied)
        XCTAssertEqual(status[.cppRuntime]?.state, .applied)
        for url in engine.dllDestinations {
            XCTAssertEqual(FileHash.sha256(of: url), FileHash.sha256(of: box.payload), url.path)
        }
        // GamingRepair is no longer touched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: game.gamingRepairDirectory.path))

        // Applying again is harmless and keeps the original backup.
        try engine.apply(Set(FixItem.allCases))
        XCTAssertEqual(engine.manifest?.installedFiles.count, 3)

        try engine.undo()
        XCTAssertEqual(try Data(contentsOf: system32DLL), Data("wine builtin".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: game.root.appendingPathComponent("xgameruntime.dll").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: game.shippingDirectory.appendingPathComponent("xgameruntime.dll").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: game.gamingRepairDirectory.appendingPathComponent("GamingRepair.exe").path))
        XCTAssertEqual(engine.registry.storedOverrides(), ["msvcp140": "builtin"])
        XCTAssertNil(engine.manifest)
    }

    func testUndoRestoresGamingRepairFromEarlierVersions() throws {
        let box = try Sandbox()
        let engine = box.engine()
        let game = try XCTUnwrap(engine.game)
        try FileManager.default.moveItem(at: game.gamingRepairDirectory, to: game.gamingRepairSetAside)
        var manifest = FixManifest(bottlePath: box.bottle.url.path)
        manifest.gamingRepairPath = game.gamingRepairDirectory.path
        try box.store.save(manifest, for: box.bottle)

        try engine.undo()
        XCTAssertTrue(FileManager.default.fileExists(atPath: game.gamingRepairDirectory.appendingPathComponent("GamingRepair.exe").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: game.gamingRepairSetAside.path))
    }

    func testCppFixWorksWithoutGame() throws {
        let box = try Sandbox(withGame: false)
        let engine = box.engine()
        XCTAssertEqual(engine.status(overrides: [:])[.gamingServices]?.state, .unavailable)
        XCTAssertThrowsError(try engine.apply([.gamingServices])) { XCTAssertEqual($0 as? FixError, .gameNotFound) }
        try engine.apply([.cppRuntime])
        XCTAssertEqual(engine.status(overrides: engine.registry.storedOverrides())[.cppRuntime]?.state, .applied)
    }

    func testRefusesWhileGameRuns() throws {
        let box = try Sandbox()
        XCTAssertThrowsError(try box.engine(gameRunning: true).apply([.cppRuntime])) {
            XCTAssertEqual($0 as? FixError, .gameRunning)
        }
    }

    func testRefusesWhileSteamRuns() throws {
        let box = try Sandbox()
        XCTAssertThrowsError(try box.engine(steamRunning: true).apply([.cppRuntime])) {
            XCTAssertEqual($0 as? FixError, .steamRunning)
        }
        // Removing the fixes is fine with Steam open.
        try box.engine().apply([.cppRuntime])
        try box.engine(steamRunning: true).undo()
        XCTAssertNil(box.store.load(for: box.bottle))
    }

    func testRejectsDamagedPayload() throws {
        let box = try Sandbox()
        let engine = box.engine()
        engine.expectedHash = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try engine.apply([.gamingServices])) { XCTAssertEqual($0 as? FixError, .payloadDamaged) }
    }

    func testManifestRoundTrip() throws {
        let box = try Sandbox()
        var manifest = FixManifest(bottlePath: box.bottle.url.path)
        manifest.previousOverrides = ["a": nil, "b": "builtin"]
        manifest.installedFiles = [.init(path: "/x", backupPath: nil)]
        try box.store.save(manifest, for: box.bottle)
        let loaded = try XCTUnwrap(box.store.load(for: box.bottle))
        XCTAssertEqual(loaded.previousOverrides.count, 2)
        XCTAssertEqual(loaded.previousOverrides["a"], .some(nil))
        XCTAssertEqual(loaded.previousOverrides["b"], .some("builtin"))
        XCTAssertEqual(loaded.installedFiles, manifest.installedFiles)
    }
}

final class ApplySummaryTests: XCTestCase {
    private let notApplied = FixStatus(.notApplied, "")
    private let applied = FixStatus(.applied, "")

    func testCppOnlyHasNoSignInStep() {
        let summary = ApplySummary(applied: [.cppRuntime], before: [.cppRuntime: notApplied], bottleName: "Steam")
        XCTAssertEqual(summary.entries.map(\.text), ["C++ runtime fix: 5 overrides set"])
        XCTAssertFalse(summary.mentionsSignIn)
        XCTAssertEqual(summary.nextSteps.count, 2)
        XCTAssertTrue(summary.changedAnything)
    }

    func testGamingServicesAddsSignIn() {
        let summary = ApplySummary(applied: [.gamingServices, .cppRuntime],
                                   before: [.gamingServices: notApplied, .cppRuntime: applied], bottleName: "Steam")
        XCTAssertTrue(summary.mentionsSignIn)
        XCTAssertEqual(summary.nextSteps.count, 3)
        XCTAssertEqual(summary.entries.last?.text, "C++ runtime fix: already in place")
    }

    func testNothingChanged() {
        let summary = ApplySummary(applied: [.cppRuntime], before: [.cppRuntime: applied], bottleName: "Steam")
        XCTAssertFalse(summary.changedAnything)
        XCTAssertEqual(summary.title, "Nothing to change")
        XCTAssertTrue(summary.nextSteps.isEmpty)
    }

    func testSignInNotShownWhenGamingServicesWasAlreadyInstalled() {
        let summary = ApplySummary(applied: [.gamingServices, .cppRuntime],
                                   before: [.gamingServices: applied, .cppRuntime: notApplied], bottleName: "Steam")
        XCTAssertFalse(summary.mentionsSignIn)
    }
}
