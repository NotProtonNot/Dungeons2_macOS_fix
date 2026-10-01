import Foundation

/// One copy of CrossOver.app on this Mac. People sometimes keep several versions side by side.
public struct CrossOverInstall: Identifiable, Hashable {
    public let appURL: URL
    public let version: String

    public var id: String { appURL.path }

    /// "CrossOver 25.1.1", or "My CrossOver Copy (25.1.1)" for a renamed app.
    public var displayName: String {
        let base = appURL.deletingPathExtension().lastPathComponent
        return base.hasPrefix("CrossOver") ? "CrossOver \(version)" : "\(base) (\(version))"
    }

    /// CrossOver's command-line Wine launcher. It understands `--bottle`.
    public var wineBinary: URL {
        appURL.appendingPathComponent("Contents/SharedSupport/CrossOver/bin/wine")
    }

    public var hasWine: Bool {
        FileManager.default.isExecutableFile(atPath: wineBinary.path)
    }

    public init?(appURL: URL) {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              (plist["CFBundleIdentifier"] as? String) == CrossOverLocator.bundleIdentifier
        else { return nil }
        self.appURL = appURL.standardizedFileURL
        self.version = (plist["CFBundleShortVersionString"] as? String)
            ?? (plist["CFBundleVersion"] as? String)
            ?? "?"
    }
}

public enum CrossOverLocator {
    public static let bundleIdentifier = "com.codeweavers.CrossOver"

    /// The only places CrossOver is looked for: the Applications folders.
    /// Copies elsewhere (Downloads, the Trash, backups, disk images) are ignored.
    public static var standardSearchDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
        ]
    }

    /// Finds every CrossOver.app, newest version first.
    /// - Parameter additional: apps the user picked by hand with "Other…".
    public static func find(additional: [URL] = [], searchDirectories: [URL] = standardSearchDirectories) -> [CrossOverInstall] {
        let fm = FileManager.default
        var candidates = additional
        for dir in searchDirectories {
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            candidates += items.filter { $0.pathExtension == "app" }
        }
        var seen = Set<String>()
        var found: [CrossOverInstall] = []
        for url in candidates {
            let key = url.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
            guard !seen.contains(key), let install = CrossOverInstall(appURL: url) else { continue }
            seen.insert(key)
            found.append(install)
        }
        return found.sorted {
            let order = $0.version.compare($1.version, options: .numeric)
            return order == .orderedSame
                ? $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                : order == .orderedDescending
        }
    }
}
