import Foundation

/// Leitor (só leitura) dos arquivos de registro do Wine (`system.reg`, `user.reg`).
///
/// Formato:
/// ```
/// [Software\\Classes\\.txt] 1700000000
/// @="txtfile"
/// "Content Type"="text/plain"
/// [Software\\Classes\\txtfile\\shell\\open\\command] 1700000000
/// @=str(2):"%SystemRoot%\\system32\\NOTEPAD.EXE %1"
/// ```
/// Só valores de texto são lidos; dword/hex são ignorados.
public struct RegistryFile: Sendable {
    /// chave (minúsculas, separada por `\`) → nome do valor (minúsculo, `@` = padrão) → texto
    public private(set) var keys: [String: [String: String]] = [:]

    public init(text: String) {
        var current: String?
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                current = Self.parseKey(line)
                if let current, keys[current] == nil { keys[current] = [:] }
            } else if let key = current, let (name, value) = Self.parseValue(line) {
                keys[key, default: [:]][name] = value
            }
        }
    }

    public init(contentsOf url: URL) {
        let data = (try? Data(contentsOf: url)) ?? Data()
        self.init(text: String(decoding: data, as: UTF8.self))
    }

    /// Valor de texto. `name` nil = valor padrão (`@`).
    public func value(_ key: String, _ name: String? = nil) -> String? {
        keys[Self.normalize(key)]?[name?.lowercased() ?? "@"]
    }

    /// Subchaves diretas de `key` (nomes como gravados, em minúsculas).
    public func subkeys(of key: String) -> [String] {
        let prefix = Self.normalize(key) + "\\"
        var result = Set<String>()
        for k in keys.keys where k.hasPrefix(prefix) {
            if let first = k.dropFirst(prefix.count).split(separator: "\\").first { result.insert(String(first)) }
        }
        return result.sorted()
    }

    static func normalize(_ key: String) -> String {
        key.lowercased().split(separator: "\\", omittingEmptySubsequences: true).joined(separator: "\\")
    }

    /// `[Software\\Classes\\.txt] 123` → `software\classes\.txt`
    static func parseKey(_ line: String) -> String? {
        guard let end = line.lastIndex(of: "]") else { return nil }
        let inner = line[line.index(after: line.startIndex)..<end]
        return normalize(unescape(String(inner)))
    }

    /// `"Nome"="valor"`, `@="valor"`, `@=str(2):"valor"`
    static func parseValue(_ line: String) -> (String, String)? {
        let name: String
        var rest: Substring
        if line.hasPrefix("@=") {
            name = "@"
            rest = line.dropFirst(2)
        } else if line.hasPrefix("\"") {
            guard let close = closingQuote(in: line, from: line.index(after: line.startIndex)) else { return nil }
            name = unescape(String(line[line.index(after: line.startIndex)..<close])).lowercased()
            rest = line[line.index(after: close)...]
            guard rest.hasPrefix("=") else { return nil }
            rest = rest.dropFirst()
        } else {
            return nil
        }
        if rest.hasPrefix("str(") {
            guard let colon = rest.firstIndex(of: ":") else { return nil }
            rest = rest[rest.index(after: colon)...]
        }
        let data = String(rest)
        guard data.hasPrefix("\""), let close = closingQuote(in: data, from: data.index(after: data.startIndex)) else { return nil }
        return (name, unescape(String(data[data.index(after: data.startIndex)..<close])))
    }

    private static func closingQuote(in s: String, from start: String.Index) -> String.Index? {
        var i = start
        while i < s.endIndex {
            if s[i] == "\\" {
                i = s.index(after: i)
                if i < s.endIndex { i = s.index(after: i) }
                continue
            }
            if s[i] == "\"" { return i }
            i = s.index(after: i)
        }
        return nil
    }

    static func unescape(_ s: String) -> String {
        var out = ""
        var iterator = s.makeIterator()
        while let c = iterator.next() {
            guard c == "\\", let n = iterator.next() else { out.append(c); continue }
            switch n {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "0": out.append("\0")
            default: out.append(n)
            }
        }
        return out
    }
}
