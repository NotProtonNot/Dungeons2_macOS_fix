import CryptoKit
import Foundation

extension FileManager {
    func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    func isFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
    }

    /// Replaces (or creates) `destination` with a copy of `source` without ever leaving it half written.
    func copyReplacing(_ source: URL, to destination: URL) throws {
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        try copyItem(at: source, to: staging)
        do {
            if fileExists(atPath: destination.path) {
                _ = try replaceItemAt(destination, withItemAt: staging)
            } else {
                try moveItem(at: staging, to: destination)
            }
        } catch {
            try? removeItem(at: staging)
            throw error
        }
    }
}

public enum FileHash {
    public static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return sha256(data)
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public extension URL {
    /// `~/Library/...` style path for display.
    var abbreviatedPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + String(path.dropFirst(home.count)) : path
    }
}
