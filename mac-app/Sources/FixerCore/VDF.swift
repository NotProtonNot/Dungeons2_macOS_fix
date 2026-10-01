import Foundation

/// Valve's KeyValues text format, used by Steam's libraryfolders.vdf and appmanifest_*.acf.
public struct VDFPair: Equatable {
    public let key: String
    public let value: VDFValue
}

public enum VDFValue: Equatable {
    case string(String)
    case object([VDFPair])

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var object: [VDFPair]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// Case-insensitive lookup, like Steam itself.
    public subscript(key: String) -> VDFValue? {
        object?.value(for: key)
    }

    /// Every string value stored under `key`, at any depth.
    public func strings(forKey key: String) -> [String] {
        guard let pairs = object else { return [] }
        return pairs.flatMap { pair -> [String] in
            if case .string(let s) = pair.value, pair.key.caseInsensitiveCompare(key) == .orderedSame { return [s] }
            return pair.value.strings(forKey: key)
        }
    }
}

public extension Array where Element == VDFPair {
    func value(for key: String) -> VDFValue? {
        first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }
}

public enum VDF {
    public struct ParseError: Error {}

    public static func parse(_ text: String) throws -> [VDFPair] {
        let tokens = try tokenize(text)
        var index = 0
        return try parseObject(tokens, &index, topLevel: true)
    }

    private enum Token {
        case string(String)
        case open
        case close
    }

    private static func tokenize(_ text: String) throws -> [Token] {
        let s = Array(text.unicodeScalars)
        var tokens: [Token] = []
        var i = 0
        while i < s.count {
            let c = s[i]
            if c == "{" {
                tokens.append(.open)
                i += 1
            } else if c == "}" {
                tokens.append(.close)
                i += 1
            } else if c == "\"" {
                i += 1
                var out = String.UnicodeScalarView()
                var closed = false
                while i < s.count {
                    let d = s[i]
                    if d == "\\", i + 1 < s.count {
                        let n = s[i + 1]
                        switch n {
                        case "n": out.append("\n")
                        case "t": out.append("\t")
                        case "\\": out.append("\\")
                        case "\"": out.append("\"")
                        default:
                            out.append(d)
                            out.append(n)
                        }
                        i += 2
                    } else if d == "\"" {
                        closed = true
                        i += 1
                        break
                    } else {
                        out.append(d)
                        i += 1
                    }
                }
                guard closed else { throw ParseError() }
                tokens.append(.string(String(out)))
            } else if c == "/", i + 1 < s.count, s[i + 1] == "/" {
                while i < s.count, s[i] != "\n" { i += 1 }
            } else if c.properties.isWhitespace {
                i += 1
            } else {
                var out = String.UnicodeScalarView()
                while i < s.count, !s[i].properties.isWhitespace, s[i] != "{", s[i] != "}", s[i] != "\"" {
                    out.append(s[i])
                    i += 1
                }
                tokens.append(.string(String(out)))
            }
        }
        return tokens
    }

    private static func parseObject(_ tokens: [Token], _ i: inout Int, topLevel: Bool) throws -> [VDFPair] {
        var pairs: [VDFPair] = []
        while i < tokens.count {
            switch tokens[i] {
            case .close:
                guard !topLevel else { throw ParseError() }
                i += 1
                return pairs
            case .open:
                throw ParseError()
            case .string(let key):
                i += 1
                guard i < tokens.count else { throw ParseError() }
                switch tokens[i] {
                case .string(let value):
                    pairs.append(VDFPair(key: key, value: .string(value)))
                    i += 1
                case .open:
                    i += 1
                    pairs.append(VDFPair(key: key, value: .object(try parseObject(tokens, &i, topLevel: false))))
                case .close:
                    throw ParseError()
                }
            }
        }
        guard topLevel else { throw ParseError() }
        return pairs
    }
}
