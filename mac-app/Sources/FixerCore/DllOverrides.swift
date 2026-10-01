import Foundation

/// Wine's per-bottle DLL overrides: what winecfg's Libraries tab edits.
/// They live under HKEY_CURRENT_USER\Software\Wine\DllOverrides, stored in the bottle's user.reg.
public enum DllOverrides {
    public static let native = "native"
    public static let nativeThenBuiltin = "native,builtin"

    /// Registry changes: a value to set, or nil to delete the override.
    public typealias Changes = [String: String?]

    /// Names are compared without case and without winecfg's optional `*` prefix.
    public static func normalizedName(_ name: String) -> String {
        (name.hasPrefix("*") ? String(name.dropFirst()) : name).lowercased()
    }

    /// Normalizes "Native, Builtin" and "native,builtin" to the same thing.
    public static func normalizedValue(_ value: String) -> String {
        value.lowercased().filter { !$0.isWhitespace }
    }

    // MARK: user.reg

    private static let sectionHeader = #"[software\\wine\\dlloverrides]"#

    private static func isHeader(_ line: String) -> Bool {
        line.lowercased().hasPrefix(sectionHeader)
    }

    /// Current overrides as stored in a user.reg file.
    public static func read(userReg text: String) -> [String: String] {
        let lines = text.components(separatedBy: "\n")
        guard let header = lines.firstIndex(where: isHeader) else { return [:] }
        var result: [String: String] = [:]
        for line in lines[(header + 1)...] {
            if line.hasPrefix("[") { break }
            if let (name, value) = parseValueLine(line) {
                result[normalizedName(name)] = value
            }
        }
        return result
    }

    /// Returns user.reg with `changes` applied. Only used while Wine is not running for the bottle;
    /// otherwise Wine would overwrite the file from memory.
    public static func updating(userReg text: String, with changes: Changes, now: Date = Date()) -> String {
        var lines = text.components(separatedBy: "\n")
        let changed = Set(changes.keys.map(normalizedName))
        let newLines = changes.keys.sorted().compactMap { name -> String? in
            guard let value = changes[name] ?? nil else { return nil }
            return "\(quoted(name))=\(quoted(value))"
        }

        if let header = lines.firstIndex(where: isHeader) {
            var end = header + 1
            while end < lines.count, !lines[end].hasPrefix("[") { end += 1 }
            var body = Array(lines[(header + 1)..<end]).filter { line in
                guard let (name, _) = parseValueLine(line) else { return true }
                return !changed.contains(normalizedName(name))
            }
            // Keep the blank line that separates sections at the end.
            var insertAt = body.count
            while insertAt > 0, body[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertAt -= 1 }
            body.insert(contentsOf: newLines, at: insertAt)
            lines.replaceSubrange((header + 1)..<end, with: body)
            return lines.joined(separator: "\n")
        }

        guard !newLines.isEmpty else { return text }
        var result = text
        if !result.hasSuffix("\n") { result += "\n" }
        if !result.hasSuffix("\n\n") { result += "\n" }
        let seconds = Int(now.timeIntervalSince1970)
        let fileTime = UInt64(max(0, now.timeIntervalSince1970 + 11_644_473_600) * 10_000_000)
        result += #"[Software\\Wine\\DllOverrides] "# + "\(seconds)\n"
        result += "#time=\(String(fileTime, radix: 16))\n"
        result += newLines.joined(separator: "\n") + "\n"
        return result
    }

    private static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Parses `"name"="value"`. Other value types (hex, dword) are ignored.
    static func parseValueLine(_ line: String) -> (String, String)? {
        var rest = Substring(line)
        guard let name = readQuoted(&rest), rest.hasPrefix("=") else { return nil }
        rest = rest.dropFirst()
        guard let value = readQuoted(&rest) else { return nil }
        return (name, value)
    }

    private static func readQuoted(_ s: inout Substring) -> String? {
        guard s.first == "\"" else { return nil }
        var out = ""
        var i = s.index(after: s.startIndex)
        while i < s.endIndex {
            let c = s[i]
            if c == "\\" {
                let next = s.index(after: i)
                guard next < s.endIndex else { return nil }
                out.append(s[next])
                i = s.index(after: next)
            } else if c == "\"" {
                s = s[s.index(after: i)...]
                return out
            } else {
                out.append(c)
                i = s.index(after: i)
            }
        }
        return nil
    }

    // MARK: Talking to Wine

    /// A .reg file for `regedit /S`, in the UTF-16 format regedit expects.
    public static func regFile(for changes: Changes) -> Data {
        var text = "Windows Registry Editor Version 5.00\r\n\r\n"
        text += "[HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides]\r\n"
        for name in changes.keys.sorted() {
            if let value = changes[name] ?? nil {
                text += "\(quoted(name))=\(quoted(value))\r\n"
            } else {
                text += "\(quoted(name))=-\r\n"
            }
        }
        text += "\r\n"
        var data = Data([0xFF, 0xFE])
        data.append(text.data(using: .utf16LittleEndian)!)
        return data
    }

    /// Parses `reg query` output: `    msvcp140    REG_SZ    native,builtin`.
    public static func parseRegQuery(_ output: String) -> [String: String] {
        var result: [String: String] = [:]
        let pattern = try! NSRegularExpression(pattern: #"^\s+(\S+)\s+REG_\w+\s*(.*?)\s*$"#)
        for line in output.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..., in: line)
            guard let match = pattern.firstMatch(in: line, range: range),
                  let name = Range(match.range(at: 1), in: line),
                  let value = Range(match.range(at: 2), in: line)
            else { continue }
            result[normalizedName(String(line[name]))] = String(line[value])
        }
        return result
    }
}
