import Foundation

/// Parser mínimo de atalhos do Windows (.lnk, formato MS-SHLLINK).
/// Extrai o que o Vinho precisa: alvo, argumentos, diretório e ícone.
public struct LnkFile: Equatable, Sendable {
    public var targetPath: String?
    public var relativePath: String?
    public var workingDirectory: String?
    public var arguments: String?
    public var iconLocation: String?

    public init(targetPath: String? = nil, relativePath: String? = nil, workingDirectory: String? = nil,
                arguments: String? = nil, iconLocation: String? = nil) {
        self.targetPath = targetPath
        self.relativePath = relativePath
        self.workingDirectory = workingDirectory
        self.arguments = arguments
        self.iconLocation = iconLocation
    }

    private enum Flag {
        static let hasTargetIDList: UInt32 = 0x01
        static let hasLinkInfo: UInt32 = 0x02
        static let hasName: UInt32 = 0x04
        static let hasRelativePath: UInt32 = 0x08
        static let hasWorkingDir: UInt32 = 0x10
        static let hasArguments: UInt32 = 0x20
        static let hasIconLocation: UInt32 = 0x40
        static let isUnicode: UInt32 = 0x80
    }

    public static func parse(contentsOf url: URL) -> LnkFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    public static func parse(_ data: Data) -> LnkFile? {
        let r = ByteReader(data)
        guard r.u32(0) == 0x4C, let flags = r.u32(0x14) else { return nil }
        var o = 0x4C
        var lnk = LnkFile()

        if flags & Flag.hasTargetIDList != 0 {
            guard let size = r.u16(o) else { return nil }
            o += 2 + Int(size)
        }

        if flags & Flag.hasLinkInfo != 0 {
            guard let size = r.u32(o), let headerSize = r.u32(o + 4), let infoFlags = r.u32(o + 8) else { return nil }
            if infoFlags & 0x1 != 0 { // VolumeIDAndLocalBasePath
                var base: String?
                var suffix: String?
                if headerSize >= 0x24 {
                    if let off = r.u32(o + 0x1C), off != 0 { base = r.utf16CString(o + Int(off)) }
                    if let off = r.u32(o + 0x20), off != 0 { suffix = r.utf16CString(o + Int(off)) }
                }
                if base == nil, let off = r.u32(o + 0x10), off != 0 { base = r.cString(o + Int(off)) }
                if suffix == nil, let off = r.u32(o + 0x18), off != 0 { suffix = r.cString(o + Int(off)) }
                if let base {
                    lnk.targetPath = base + (suffix ?? "")
                }
            }
            o += Int(size)
        }

        let unicode = flags & Flag.isUnicode != 0
        func readString() -> String? {
            guard let count = r.u16(o).map(Int.init) else { return nil }
            o += 2
            let value = unicode ? r.utf16(o, count: count) : r.latin1(o, count: count)
            o += unicode ? count * 2 : count
            return value
        }

        if flags & Flag.hasName != 0 { _ = readString() }
        if flags & Flag.hasRelativePath != 0 { lnk.relativePath = readString() }
        if flags & Flag.hasWorkingDir != 0 { lnk.workingDirectory = readString() }
        if flags & Flag.hasArguments != 0 { lnk.arguments = readString() }
        if flags & Flag.hasIconLocation != 0 { lnk.iconLocation = readString() }
        return lnk
    }
}

extension WindowsPath {
    /// `C:\Games\Jogo.exe` → `<bottle>/drive_c/Games/Jogo.exe`.
    /// Outras letras passam por `dosdevices/<letra>:`. Resolve maiúsculas/minúsculas.
    public static func toUnix(_ windowsPath: String, in bottle: Bottle) -> URL? {
        let path = windowsPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "\" ").union(.whitespaces))
            .replacingOccurrences(of: "\\", with: "/")
        let chars = Array(path)
        guard chars.count >= 2, chars[1] == ":", chars[0].isLetter else { return nil }

        let letter = String(chars[0]).lowercased()
        let rest = String(chars.dropFirst(2))
        let root = letter == "c"
            ? bottle.driveC
            : bottle.url.appendingPathComponent("dosdevices/\(letter):", isDirectory: true).resolvingSymlinksInPath()
        return resolveCaseInsensitive(rest.split(separator: "/").map(String.init), from: root)
    }

    static func resolveCaseInsensitive(_ components: [String], from root: URL) -> URL {
        let fm = FileManager.default
        var url = root
        for component in components where !component.isEmpty {
            let direct = url.appendingPathComponent(component)
            if fm.fileExists(atPath: direct.path) {
                url = direct
                continue
            }
            let names = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            if let match = names.first(where: { $0.caseInsensitiveCompare(component) == .orderedSame }) {
                url = url.appendingPathComponent(match)
            } else {
                url = direct
            }
        }
        return url
    }
}

/// Descobre o ícone de um programa do bottle (.exe direto ou via .lnk).
public enum ProgramIconResolver {
    public static func iconData(for program: URL, in bottle: Bottle) -> Data? {
        switch program.pathExtension.lowercased() {
        case "exe":
            return PEIconExtractor.icoData(fromExecutableAt: program)
        case "lnk":
            guard let lnk = LnkFile.parse(contentsOf: program) else { return nil }
            // IconLocation tem prioridade ("C:\x\app.ico" ou "C:\x\app.exe,0").
            if let location = lnk.iconLocation, !location.isEmpty,
               let path = location.split(separator: ",").first.map(String.init),
               let url = WindowsPath.toUnix(path, in: bottle) {
                switch url.pathExtension.lowercased() {
                case "ico":
                    if let data = try? Data(contentsOf: url) { return data }
                case "exe", "dll":
                    if let data = PEIconExtractor.icoData(fromExecutableAt: url) { return data }
                default: break
                }
            }
            if let target = lnk.targetPath, let url = WindowsPath.toUnix(target, in: bottle) {
                return PEIconExtractor.icoData(fromExecutableAt: url)
            }
            return nil
        default:
            return nil
        }
    }
}
