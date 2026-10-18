import Foundation

/// Gera mini-apps `.app` que abrem um programa do Windows direto do
/// Launchpad/Spotlight/Dock, sem precisar abrir o Vinho.
///
/// O app contém só um script `sh` com um *snapshot* do ambiente do bottle.
/// Se as configurações do bottle mudarem, recrie o atalho.
public enum LauncherBuilder {
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Vinho", isDirectory: true)
    }

    /// Script de lançamento. Variáveis herdadas (HOME, USER…) vêm do sistema
    /// na hora da execução e não são gravadas.
    public static func script(for invocation: WineInvocation, skipping inherited: Set<String> = Set(WineEnvironment.inheritedKeys)) -> String {
        var lines = [
            "#!/bin/sh",
            "# Gerado pelo Vinho. Recrie o atalho se mudar as configurações do bottle.",
        ]
        for key in invocation.environment.keys.sorted() where !inherited.contains(key) && isValidShellName(key) {
            lines.append("export \(key)=\(shellQuote(invocation.environment[key] ?? ""))")
        }
        if let cwd = invocation.currentDirectory {
            lines.append("cd \(shellQuote(cwd.path)) 2>/dev/null")
        }
        lines.append((["exec", shellQuote(invocation.executable.path)] + invocation.arguments.map(shellQuote)).joined(separator: " "))
        return lines.joined(separator: "\n") + "\n"
    }

    @discardableResult
    public static func makeApp(named name: String, invocation: WineInvocation, in directory: URL) throws -> URL {
        let fm = FileManager.default
        let safeName = sanitize(name)
        let app = directory.appendingPathComponent("\(safeName).app", isDirectory: true)
        if fm.fileExists(atPath: app.path) { try fm.removeItem(at: app) }

        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "CFBundleExecutable": "launcher",
            "CFBundleIdentifier": "dev.leandro.vinho.launcher.\(BottleManager.slug(name).lowercased())",
            "CFBundleName": safeName,
            "CFBundleDisplayName": safeName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "LSMinimumSystemVersion": "14.0",
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: app.appendingPathComponent("Contents/Info.plist"))

        let launcher = macOS.appendingPathComponent("launcher")
        try script(for: invocation).write(to: launcher, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        return app
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    static func isValidShellName(_ key: String) -> Bool {
        guard let first = key.first, first == "_" || first.isLetter else { return false }
        return key.allSatisfy { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
    }

    static func sanitize(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Programa" : cleaned
    }
}
