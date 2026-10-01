import Foundation

/// A CrossOver bottle: a self-contained Wine prefix with its own C: drive and registry.
public struct Bottle: Identifiable, Hashable {
    public let url: URL

    public init(url: URL) {
        self.url = url.standardizedFileURL
    }

    public var id: String { url.path }
    public var name: String { url.lastPathComponent }
    public var driveC: URL { url.appendingPathComponent("drive_c", isDirectory: true) }
    public var system32: URL { driveC.appendingPathComponent("windows/system32", isDirectory: true) }
    public var tempDirectory: URL { driveC.appendingPathComponent("windows/temp", isDirectory: true) }
    public var userRegistry: URL { url.appendingPathComponent("user.reg") }

    /// The game is 64-bit only. Every bottle made by CrossOver 22 or later is 64-bit.
    public var is64Bit: Bool {
        FileManager.default.isDirectory(driveC.appendingPathComponent("windows/syswow64"))
    }

    /// Maps a Windows path such as `D:\Games\Steam` to where it lives on the Mac,
    /// following the bottle's `dosdevices` drive links.
    public func unixURL(forWindowsPath path: String) -> URL? {
        let chars = Array(path)
        guard chars.count >= 2, chars[1] == ":", chars[0].isLetter else { return nil }
        let letter = chars[0].lowercased()
        let components = String(chars.dropFirst(2))
            .split(whereSeparator: { $0 == "\\" || $0 == "/" })
            .map(String.init)

        var base: URL
        let link = url.appendingPathComponent("dosdevices/\(letter):")
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) {
            base = destination.hasPrefix("/")
                ? URL(fileURLWithPath: destination, isDirectory: true)
                : link.deletingLastPathComponent().appendingPathComponent(destination, isDirectory: true)
        } else if letter == "c" {
            base = driveC
        } else {
            return nil
        }
        for component in components {
            base.appendPathComponent(component)
        }
        return base.standardizedFileURL
    }
}

public enum BottleLocator {
    /// Where CrossOver keeps bottles unless the user moved them.
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CrossOver/Bottles", isDirectory: true)
    }

    public static func isBottle(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.isFile(url.appendingPathComponent("cxbottle.conf"))
            || (fm.isDirectory(url.appendingPathComponent("drive_c")) && fm.isFile(url.appendingPathComponent("system.reg")))
    }

    /// Every bottle inside the given folders, sorted by name.
    public static func bottles(in directories: [URL]) -> [Bottle] {
        let fm = FileManager.default
        var seen = Set<String>()
        var result: [Bottle] = []
        for dir in directories {
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for item in items where isBottle(item) {
                let bottle = Bottle(url: item)
                if seen.insert(bottle.url.resolvingSymlinksInPath().path.lowercased()).inserted {
                    result.append(bottle)
                }
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// CrossOver lets people move their bottles. Rather than depend on one preference key,
    /// look at every folder named in CrossOver's preferences and keep those that hold bottles.
    public static func directories(fromPreferences preferences: [String: Any]) -> [URL] {
        var paths: [String] = []
        func collect(_ value: Any) {
            switch value {
            case let s as String: paths.append(s)
            case let a as [Any]: a.forEach(collect)
            case let d as [String: Any]: d.values.forEach(collect)
            default: break
            }
        }
        preferences.values.forEach(collect)

        let fm = FileManager.default
        return paths.compactMap { raw -> URL? in
            let expanded = (raw.hasPrefix("file://") ? URL(string: raw)?.path : nil) ?? (raw as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else { return nil }
            let url = URL(fileURLWithPath: expanded, isDirectory: true)
            guard fm.isDirectory(url) else { return nil }
            return bottles(in: [url]).isEmpty ? nil : url.standardizedFileURL
        }
    }
}
