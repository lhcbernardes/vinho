import Foundation

/// Um tipo de arquivo que um programa do Windows registrou para abrir.
public struct WindowsFileAssociation: Hashable, Sendable {
    /// Sem ponto, minúsculo (`docx`).
    public let fileExtension: String
    public let progID: String
    public let description: String?
    /// Caminho do Windows do executável.
    public let program: String
    /// Argumentos com `%1` onde entra o arquivo.
    public let arguments: [String]
}

/// Programa do Windows com os tipos de arquivo que ele abre (vira um app no "Abrir com").
public struct AssociatedProgram: Hashable, Sendable {
    public let program: String
    public let arguments: [String]
    public let extensions: [String]
    public let typeName: String

    public var displayName: String {
        let file = program.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? program
        return (file as NSString).deletingPathExtension
    }
}

/// Integração do bottle com o macOS — equivalente ao cxassoc/cxmenu/cxnativeopen do CrossOver.
public enum MacIntegration {
    // MARK: Associações de arquivo (Windows → "Abrir com" do Finder)

    public static let nativeOpenProgID = "Vinho.MacOpen"

    public static func registries(of bottle: Bottle) -> (system: RegistryFile, user: RegistryFile) {
        (RegistryFile(contentsOf: bottle.prefixURL.appendingPathComponent("system.reg")),
         RegistryFile(contentsOf: bottle.prefixURL.appendingPathComponent("user.reg")))
    }

    /// Associações de programas instalados (ignora os do próprio Wine em C:\windows).
    public static func fileAssociations(system: RegistryFile, user: RegistryFile) -> [WindowsFileAssociation] {
        var result: [String: WindowsFileAssociation] = [:]
        // HKCU sobrepõe HKLM, como no HKEY_CLASSES_ROOT do Windows.
        for (registry, root) in [(system, "Software\\Classes"), (user, "Software\\Classes")] {
            for name in registry.subkeys(of: root) where name.hasPrefix(".") && name.count > 1 {
                let ext = String(name.dropFirst())
                guard ext.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }),
                      let progID = registry.value("\(root)\\\(name)"), !progID.isEmpty,
                      progID != nativeOpenProgID else { continue }
                // O ProgID pode estar no mesmo arquivo ou no outro.
                let command = [user, system].lazy
                    .compactMap { openCommand(progID: progID, in: $0) }.first
                guard let command, let parsed = parseCommand(command), !isSystemProgram(parsed.program) else { continue }
                let description = user.value("Software\\Classes\\\(progID)") ?? system.value("Software\\Classes\\\(progID)")
                result[ext] = WindowsFileAssociation(fileExtension: ext, progID: progID, description: description,
                                                     program: parsed.program, arguments: parsed.arguments)
            }
        }
        return result.values.sorted { $0.fileExtension < $1.fileExtension }
    }

    static func openCommand(progID: String, in registry: RegistryFile) -> String? {
        let base = "Software\\Classes\\\(progID)\\shell"
        let verb = registry.value(base)?.nilIfEmpty ?? "open"
        return registry.value("\(base)\\\(verb)\\command") ?? registry.value("\(base)\\open\\command")
    }

    /// Agrupa por programa: um app no Mac por executável.
    public static func programs(from associations: [WindowsFileAssociation]) -> [AssociatedProgram] {
        Dictionary(grouping: associations) { $0.program.lowercased() }
            .values
            .compactMap { group -> AssociatedProgram? in
                guard let first = group.first else { return nil }
                return AssociatedProgram(
                    program: first.program, arguments: first.arguments,
                    extensions: group.map(\.fileExtension).sorted(),
                    typeName: first.description ?? "Documento"
                )
            }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// `"C:\Program Files\App\app.exe" /open "%1"` → (`C:\…\app.exe`, [`/open`, `%1`]).
    /// Também aceita caminho sem aspas com espaços (`C:\Program Files\App\app.exe %1`).
    public static func parseCommand(_ raw: String) -> (program: String, arguments: [String])? {
        let command = expandVariables(raw.trimmingCharacters(in: .whitespaces))
        guard !command.isEmpty else { return nil }
        var program: String
        var rest: String
        if command.hasPrefix("\"") {
            let body = command.dropFirst()
            guard let close = body.firstIndex(of: "\"") else { return nil }
            program = String(body[..<close])
            rest = String(body[body.index(after: close)...])
        } else if let range = command.range(of: ".exe", options: [.caseInsensitive]) {
            program = String(command[..<range.upperBound])
            rest = String(command[range.upperBound...])
        } else {
            let parts = command.split(separator: " ", maxSplits: 1)
            program = String(parts[0])
            rest = parts.count > 1 ? String(parts[1]) : ""
        }
        program = program.trimmingCharacters(in: .whitespaces)
        var args = CommandLineSplitter.split(rest).filter { !$0.hasPrefix("%") || $0 == "%1" || $0.uppercased() == "%L" }
            .map { $0.replacingOccurrences(of: "%L", with: "%1").replacingOccurrences(of: "%l", with: "%1") }
        if !args.contains(where: { $0.contains("%1") }) { args.append("%1") }
        return (program, args)
    }

    static func expandVariables(_ s: String) -> String {
        var out = s
        let table: [(String, String)] = [
            ("%ProgramFiles(x86)%", #"C:\Program Files (x86)"#),
            ("%ProgramW6432%", #"C:\Program Files"#),
            ("%ProgramFiles%", #"C:\Program Files"#),
            ("%CommonProgramFiles(x86)%", #"C:\Program Files (x86)\Common Files"#),
            ("%CommonProgramFiles%", #"C:\Program Files\Common Files"#),
            ("%SystemRoot%", #"C:\windows"#),
            ("%windir%", #"C:\windows"#),
            ("%SystemDrive%", "C:"),
        ]
        for (k, v) in table { out = out.replacingOccurrences(of: k, with: v, options: .caseInsensitive) }
        return out
    }

    /// Programas do próprio Wine (notepad, wordpad, winebrowser, rundll32…).
    public static func isSystemProgram(_ windowsPath: String) -> Bool {
        let p = windowsPath.lowercased().replacingOccurrences(of: "/", with: "\\")
        return p.hasPrefix("c:\\windows\\") || !p.contains("\\")
    }

    // MARK: Arquivos e links abrindo nos apps do Mac (cxnativeopen)

    /// Tipos que, sem um programa do Windows instalado para eles, abrem no Mac.
    public static let nativeOpenExtensions = [
        "pdf", "png", "jpg", "jpeg", "gif", "bmp", "webp", "heic", "tif", "tiff",
        "mp4", "mov", "m4v", "mp3", "m4a", "wav", "aac", "flac",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "rtf", "odt", "ods", "odp", "csv",
    ]

    static let winebrowser = #"C:\windows\system32\winebrowser.exe"#

    /// Uma alteração no HKCU.
    public enum RegistryOperation: Hashable, Sendable {
        /// `name` nil = valor padrão.
        case set(key: String, name: String?, data: String)
        case deleteKey(String)
    }

    /// Links (http/https/mailto) abrem no navegador/e-mail do Mac, e tipos sem
    /// programa do Windows abrem no app padrão do Mac. Se um programa do Windows
    /// passar a abrir um tipo, a nossa entrada sai. Só devolve o que falta mudar.
    public static func nativeOpenOperations(system: RegistryFile, user: RegistryFile) -> [RegistryOperation] {
        let classes = #"Software\Classes"#
        let open = "\"\(winebrowser)\" \"%1\""
        var wanted: [RegistryOperation] = [
            .set(key: #"Software\Wine\WineBrowser"#, name: "Browsers", data: "/usr/bin/open"),
            .set(key: #"Software\Wine\WineBrowser"#, name: "Mailers", data: "/usr/bin/open"),
            .set(key: "\(classes)\\\(nativeOpenProgID)", name: nil, data: "Abrir no Mac"),
            .set(key: "\(classes)\\\(nativeOpenProgID)\\shell\\open\\command", name: nil, data: open),
        ]
        for scheme in ["http", "https", "mailto"] {
            wanted.append(.set(key: "\(classes)\\\(scheme)\\shell\\open\\command", name: nil, data: open))
        }

        let windowsPrograms = Set(fileAssociations(system: system, user: RegistryFile(text: "")).map(\.fileExtension))
        for ext in nativeOpenExtensions {
            let key = "\(classes)\\.\(ext)"
            let ours = user.value(key) == nativeOpenProgID
            if windowsPrograms.contains(ext) || userHasWindowsProgram(ext, user: user, system: system) {
                if ours { wanted.append(.deleteKey(key)) }
            } else {
                wanted.append(.set(key: key, name: nil, data: nativeOpenProgID))
            }
        }
        return wanted.filter { op in
            switch op {
            case .set(let key, let name, let data): return user.value(key, name) != data
            case .deleteKey: return true
            }
        }
    }

    /// Arquivo `.reg` (importado de uma vez com `regedit /S`, bem mais rápido que vários `reg add`).
    public static func regFile(_ operations: [RegistryOperation]) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        var lines = ["REGEDIT4", ""]
        for op in operations {
            switch op {
            case .set(let key, let name, let data):
                lines.append("[HKEY_CURRENT_USER\\\(key)]")
                lines.append("\(name.map { "\"\(esc($0))\"" } ?? "@")=\"\(esc(data))\"")
            case .deleteKey(let key):
                lines.append("[-HKEY_CURRENT_USER\\\(key)]")
            }
            lines.append("")
        }
        return lines.joined(separator: "\r\n")
    }

    /// O usuário (HKCU) já aponta este tipo para um programa do Windows?
    static func userHasWindowsProgram(_ ext: String, user: RegistryFile, system: RegistryFile) -> Bool {
        guard let progID = user.value(#"Software\Classes\.\#(ext)"#), progID != nativeOpenProgID,
              let command = openCommand(progID: progID, in: user) ?? openCommand(progID: progID, in: system),
              let parsed = parseCommand(command) else { return false }
        return !isSystemProgram(parsed.program)
    }

    // MARK: Menu Iniciar → Launchpad (cxmenu)

    static let menuNoiseTerms = ["uninstall", "desinstal", "readme", "leia-me", "help", "ajuda", "manual",
                                 "website", "web site", "support", "release notes", "license", "licen", "remove"]

    /// Atalhos do Menu Iniciar que viram apps no Launchpad.
    public static func startMenuShortcuts(in bottle: Bottle) -> [URL] {
        let c = bottle.driveC
        var dirs = [c.appendingPathComponent("ProgramData/Microsoft/Windows/Start Menu/Programs", isDirectory: true)]
        let users = c.appendingPathComponent("users", isDirectory: true)
        for user in (try? FileManager.default.contentsOfDirectory(atPath: users.path)) ?? [] where user != "Public" {
            dirs.append(users.appendingPathComponent("\(user)/AppData/Roaming/Microsoft/Windows/Start Menu/Programs", isDirectory: true))
        }
        var seen = Set<String>()
        return dirs
            .flatMap { ProgramScanner.files(in: $0, extensions: ["lnk"], maxDepth: 4) }
            .filter { url in
                let name = url.deletingPathExtension().lastPathComponent.lowercased()
                return !ProgramScanner.isNoise(url) && !menuNoiseTerms.contains { name.contains($0) }
                    && seen.insert(name).inserted
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Um app que a integração cria no Mac.
    public struct PlannedApp: Hashable, Sendable {
        public let name: String
        /// Caminho Unix do .exe (ou do .lnk, quando o atalho não tem alvo legível).
        public let program: URL
        /// Argumentos; `%1` marca onde entra o arquivo aberto pelo Finder.
        public let template: [String]
        public let extensions: [String]
        public let typeName: String

        /// Muda quando o app precisa ser recriado.
        public var spec: String {
            ([program.path] + template + ["|"] + extensions).joined(separator: "\u{1F}")
        }
    }

    /// Junta Menu Iniciar e associações: um atalho do Menu Iniciar cujo alvo abre
    /// tipos de arquivo vira um app só, que também aparece no "Abrir com".
    public static func plan(for bottle: Bottle) -> [PlannedApp] {
        let (system, user) = registries(of: bottle)
        let associated = programs(from: fileAssociations(system: system, user: user))
        var byExe: [String: AssociatedProgram] = [:]
        for program in associated {
            if let url = WindowsPath.toUnix(program.program, in: bottle) { byExe[url.path.lowercased()] = program }
        }

        var apps: [PlannedApp] = []
        var usedExes = Set<String>()
        var names = Set<String>()
        func add(_ app: PlannedApp) {
            guard names.insert(app.name.lowercased()).inserted else { return }
            apps.append(app)
        }

        for lnk in startMenuShortcuts(in: bottle) {
            let name = lnk.deletingPathExtension().lastPathComponent
            let parsed = LnkFile.parse(contentsOf: lnk)
            let extra = CommandLineSplitter.split(parsed?.arguments ?? "")
            if let target = parsed?.targetPath, let exe = WindowsPath.toUnix(target, in: bottle),
               exe.pathExtension.lowercased() == "exe", FileManager.default.fileExists(atPath: exe.path) {
                if let program = byExe[exe.path.lowercased()] {
                    usedExes.insert(exe.path.lowercased())
                    add(PlannedApp(name: name, program: exe, template: extra + program.arguments,
                                   extensions: program.extensions, typeName: program.typeName))
                } else {
                    // Steam/Epic/GOG pelo Launchpad também abrem com as correções de tela preta.
                    let args = extra.isEmpty ? (GameLauncher.detect(exe)?.launchArguments ?? []) : extra
                    add(PlannedApp(name: name, program: exe, template: args, extensions: [], typeName: "Documento"))
                }
            } else {
                add(PlannedApp(name: name, program: lnk, template: [], extensions: [], typeName: "Documento"))
            }
        }

        for program in associated {
            guard let exe = WindowsPath.toUnix(program.program, in: bottle),
                  !usedExes.contains(exe.path.lowercased()),
                  FileManager.default.fileExists(atPath: exe.path) else { continue }
            add(PlannedApp(name: program.displayName, program: exe, template: program.arguments,
                           extensions: program.extensions, typeName: program.typeName))
        }
        return apps
    }

    /// Pasta dos apps gerados para um bottle.
    public static func appsDirectory(for bottle: Bottle, base: URL = LauncherBuilder.defaultDirectory) -> URL {
        base.appendingPathComponent(LauncherBuilder.sanitize(bottle.name), isDirectory: true)
    }
}

// MARK: - App de documento (aparece no "Abrir com")

extension LauncherBuilder {
    /// Script que abre o programa com cada arquivo recebido (convertido para `Z:\…`).
    /// Sem arquivos, só abre o programa.
    public static func documentScript(for invocation: WineInvocation, template: [String],
                                      skipping inherited: Set<String> = Set(WineEnvironment.inheritedKeys)) -> String {
        var lines = [
            "#!/bin/sh",
            "# Gerado pelo Vinho (integração com o Finder).",
        ]
        for key in invocation.environment.keys.sorted() where !inherited.contains(key) && isValidShellName(key) {
            lines.append("export \(key)=\(shellQuote(invocation.environment[key] ?? ""))")
        }
        if let cwd = invocation.currentDirectory {
            lines.append("cd \(shellQuote(cwd.path)) 2>/dev/null")
        }
        let base = ([invocation.executable.path] + invocation.arguments).map(shellQuote).joined(separator: " ")
        let withFile = template.map { token -> String in
            guard token.contains("%1") else { return shellQuote(token) }
            return token.components(separatedBy: "%1").map(shellQuote).joined(separator: "\"$w\"")
        }.joined(separator: " ")
        let withoutFile = template.filter { !$0.contains("%1") }.map(shellQuote).joined(separator: " ")
        lines += [
            "if [ $# -eq 0 ]; then",
            "  exec \(base) \(withoutFile)",
            "fi",
            "for f in \"$@\"; do",
            "  w=\"Z:$(printf '%s' \"$f\" | tr '/' '\\\\')\"",
            "  \(base) \(withFile) &",
            "done",
            "wait",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    static let specKey = "VinhoIntegrationSpec"

    /// Spec gravado num app já gerado (para não recriar o que não mudou).
    public static func spec(of app: URL) -> String? {
        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist[specKey] as? String
    }

    /// AppleScript do applet: repassa os arquivos do Finder para o script.
    public static let documentAppletSource = """
    on run
    \tdo shell script quoted form of (POSIX path of (path to me) & "Contents/Resources/vinho-open.sh") & " > /dev/null 2>&1 &"
    end run
    on open theFiles
    \tset args to ""
    \trepeat with f in theFiles
    \t\tset args to args & " " & quoted form of (POSIX path of f)
    \tend repeat
    \tdo shell script quoted form of (POSIX path of (path to me) & "Contents/Resources/vinho-open.sh") & args & " > /dev/null 2>&1 &"
    end open
    """

    /// Chaves extras do Info.plist do applet.
    public static func documentPlistEntries(name: String, identifier: String, extensions: [String], typeName: String) -> [String: Any] {
        [
            "CFBundleIdentifier": identifier,
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "LSMinimumSystemVersion": "14.0",
            "CFBundleDocumentTypes": [[
                "CFBundleTypeName": typeName,
                "CFBundleTypeRole": "Editor",
                "LSHandlerRank": "Alternate",
                "CFBundleTypeExtensions": extensions,
            ]],
        ]
    }

    /// Gera o applet com `osacompile`, grava o script e o Info.plist e assina (ad-hoc).
    @discardableResult
    public static func makeDocumentApp(named name: String, invocation: WineInvocation, template: [String],
                                       extensions: [String], typeName: String, in directory: URL,
                                       icns: Data? = nil, spec: String? = nil,
                                       launcher: any ProcessLaunching = FoundationProcessLauncher()) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = directory.appendingPathComponent("\(sanitize(name)).app", isDirectory: true)
        if fm.fileExists(atPath: app.path) { try fm.removeItem(at: app) }

        let source = fm.temporaryDirectory.appendingPathComponent("vinho-applet-\(UUID().uuidString).applescript")
        try documentAppletSource.write(to: source, atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: source) }
        try await tool("/usr/bin/osacompile", ["-o", app.path, source.path], launcher: launcher)

        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        let script = resources.appendingPathComponent("vinho-open.sh")
        try documentScript(for: invocation, template: template).write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let plistURL = app.appendingPathComponent("Contents/Info.plist")
        var plist = (try? PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil)) as? [String: Any] ?? [:]
        let identifier = "dev.leandro.vinho.open.\(BottleManager.slug(directory.lastPathComponent + "-" + name).lowercased())"
        plist.merge(documentPlistEntries(name: sanitize(name), identifier: identifier, extensions: extensions, typeName: typeName)) { _, new in new }
        if extensions.isEmpty { plist["CFBundleDocumentTypes"] = nil }
        if let spec { plist[specKey] = spec }
        if let icns {
            // O applet usa Resources/applet.icns; trocar antes de assinar mantém a assinatura válida.
            try icns.write(to: resources.appendingPathComponent("applet.icns"))
            plist["CFBundleIconFile"] = "applet"
            try? fm.removeItem(at: resources.appendingPathComponent("Assets.car"))
            plist["CFBundleIconName"] = nil
        }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)

        try await tool("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app.path], launcher: launcher)
        return app
    }

    /// Avisa o Launch Services (o app aparece no "Abrir com" na hora).
    public static func register(_ app: URL, launcher: any ProcessLaunching = FoundationProcessLauncher()) async {
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        _ = try? await tool(lsregister, ["-f", app.path], launcher: launcher)
    }

    /// Remove o registro do app no Launch Services antes de apagá-lo.
    public static func unregister(_ app: URL, launcher: any ProcessLaunching = FoundationProcessLauncher()) async {
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        _ = try? await tool(lsregister, ["-u", app.path], launcher: launcher)
    }

    @discardableResult
    private static func tool(_ path: String, _ args: [String], launcher: any ProcessLaunching) async throws -> ProcessResult {
        let result = try await launcher.collect(WineInvocation(
            executable: URL(fileURLWithPath: path), arguments: args,
            environment: ProcessInfo.processInfo.environment
        ))
        return try result.check()
    }
}
