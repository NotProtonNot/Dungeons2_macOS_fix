import Foundation

/// A Minecraft Dungeons II install folder.
public struct GameInstall: Hashable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public var launcher: URL { root.appendingPathComponent("Dungeons.exe") }
    public var shippingDirectory: URL { root.appendingPathComponent("Dungeons/Binaries/Win64", isDirectory: true) }
    public var shippingExecutable: URL { shippingDirectory.appendingPathComponent("Dungeons-Win64-Shipping.exe") }

    private var thirdParty: URL { root.appendingPathComponent("Engine/Extras/ThirdPartyNotUE", isDirectory: true) }
    /// Microsoft's Gaming Services repair tool. It can't work outside Windows and slows every launch.
    public var gamingRepairDirectory: URL { thirdParty.appendingPathComponent("GamingRepair", isDirectory: true) }
    public var gamingRepairSetAside: URL { thirdParty.appendingPathComponent("GamingRepair.disabled", isDirectory: true) }
}

public enum GameLocator {
    public static let steamAppID = "1912410"
    public static let defaultFolderName = "Minecraft Dungeons II"

    /// Checks that `url` is the game's root folder.
    /// With `searchNearby`, also accepts a folder inside the game or the `common` folder around it,
    /// because people pick whatever folder Finder happens to show.
    public static func validate(_ url: URL, searchNearby: Bool = false) -> GameInstall? {
        if let game = gameIfValid(at: url) { return game }
        guard searchNearby else { return nil }
        if let game = gameIfValid(at: url.appendingPathComponent(defaultFolderName)) { return game }
        var candidate = url.standardizedFileURL
        for _ in 0..<4 {
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else { break }
            candidate = parent
            if let game = gameIfValid(at: candidate) { return game }
        }
        return nil
    }

    private static func gameIfValid(at url: URL) -> GameInstall? {
        let fm = FileManager.default
        let game = GameInstall(root: url)
        guard fm.isDirectory(game.shippingDirectory),
              fm.isFile(game.launcher) || fm.isFile(game.shippingExecutable)
        else { return nil }
        return game
    }

    /// Finds the game in any Steam library known to the bottle's Steam.
    public static func locate(in bottle: Bottle) -> GameInstall? {
        let fm = FileManager.default
        for library in steamLibraries(in: bottle) {
            let steamapps = library.appendingPathComponent("steamapps", isDirectory: true)
            var folderNames: [String] = []
            let manifest = steamapps.appendingPathComponent("appmanifest_\(steamAppID).acf")
            if let text = try? String(contentsOf: manifest, encoding: .utf8),
               let pairs = try? VDF.parse(text),
               let installDir = pairs.value(for: "AppState")?["installdir"]?.string {
                folderNames.append(installDir)
            }
            folderNames.append(defaultFolderName)
            let common = steamapps.appendingPathComponent("common", isDirectory: true)
            for name in folderNames {
                if let game = validate(common.appendingPathComponent(name, isDirectory: true)) { return game }
            }
            // Last resort: a renamed folder that still holds the game.
            let others = (try? fm.contentsOfDirectory(at: common, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            if let game = others.lazy.compactMap({ validate($0) }).first { return game }
        }
        return nil
    }

    /// The Steam install folders inside the bottle plus every extra library they list.
    public static func steamLibraries(in bottle: Bottle) -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        func add(_ url: URL) {
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard fm.isDirectory(resolved),
                  !result.contains(where: { $0.path.lowercased() == resolved.path.lowercased() })
            else { return }
            result.append(resolved)
        }

        let roots = ["Program Files (x86)/Steam", "Program Files/Steam"]
            .map { bottle.driveC.appendingPathComponent($0, isDirectory: true) }
        for root in roots where fm.isDirectory(root) {
            add(root)
            let vdf = root.appendingPathComponent("steamapps/libraryfolders.vdf")
            guard let text = try? String(contentsOf: vdf, encoding: .utf8),
                  let pairs = try? VDF.parse(text)
            else { continue }
            var paths = VDFValue.object(pairs).strings(forKey: "path")
            // Pre-2021 format: "1" "D:\\Games"
            for pair in pairs.value(for: "libraryfolders")?.object ?? [] where Int(pair.key) != nil {
                if let path = pair.value.string { paths.append(path) }
            }
            for path in paths {
                if let url = bottle.unixURL(forWindowsPath: path) { add(url) }
            }
        }
        return result
    }
}
