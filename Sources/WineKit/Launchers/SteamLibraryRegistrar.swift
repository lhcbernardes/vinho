import Foundation

/// Registra a biblioteca compartilhada (drive S:) direto nos arquivos da Steam,
/// para o usuário não precisar de "Adicionar volume".
///
/// Escreve em `steamapps/libraryfolders.vdf` (lista de bibliotecas) e cria
/// `S:\SteamLibrary\steamapps\libraryfolder.vdf` (identidade da biblioteca).
/// Só pode rodar com a Steam FECHADA — ela reescreve esses arquivos ao sair.
public enum SteamLibraryRegistrar {
    public static let folderName = "SteamLibrary"

    /// Caminho Windows da biblioteca no drive compartilhado: `S:\SteamLibrary`.
    public static func windowsPath(letter: String = Steam.sharedLibraryDrive) -> String {
        "\(letter.uppercased()):\\\(folderName)"
    }

    /// - Returns: `true` se registrou agora, `false` se já estava registrada.
    @discardableResult
    public static func register(in bottle: Bottle, letter: String = Steam.sharedLibraryDrive,
                                contentID: String = randomContentID()) throws -> Bool {
        guard !Steam.hasLibrary(onDrive: letter, in: bottle) else { return false }
        guard let driveRoot = WindowsPath.toUnix("\(letter):\\", in: bottle) else {
            throw WineError.invalidArchive(reason: "drive \(letter.uppercased()): não montado")
        }
        let fm = FileManager.default

        // 1. Pasta da biblioteca + identidade.
        let steamapps = driveRoot.appendingPathComponent("\(folderName)/steamapps", isDirectory: true)
        try fm.createDirectory(at: steamapps, withIntermediateDirectories: true)
        let identity = steamapps.appendingPathComponent("libraryfolder.vdf")
        if !fm.fileExists(atPath: identity.path) {
            try """
            "libraryfolder"
            {
            \t"contentid"\t\t"\(contentID)"
            \t"label"\t\t""
            }

            """.write(to: identity, atomically: true, encoding: .utf8)
        }

        // 2. Entrada nova na lista de bibliotecas da Steam.
        let list = Steam.directory(in: bottle).appendingPathComponent("steamapps/libraryfolders.vdf")
        try fm.createDirectory(at: list.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = (try? String(contentsOf: list, encoding: .utf8)) ?? ""
        let updated = addingLibrary(windowsPath(letter: letter), contentID: contentID, to: existing)
        try updated.write(to: list, atomically: true, encoding: .utf8)
        return true
    }

    /// Insere um bloco de biblioteca no `libraryfolders.vdf` (puro, testável).
    static func addingLibrary(_ path: String, contentID: String, to vdf: String) -> String {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
        let block = """
        \t"\(nextIndex(in: vdf))"
        \t{
        \t\t"path"\t\t"\(escaped)"
        \t\t"label"\t\t""
        \t\t"contentid"\t\t"\(contentID)"
        \t\t"totalsize"\t\t"0"
        \t\t"apps"
        \t\t{
        \t\t}
        \t}

        """
        guard !vdf.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let close = vdf.range(of: "}", options: .backwards) else {
            // Arquivo ainda não existe: cria com a biblioteca principal + a nova.
            return """
            "libraryfolders"
            {
            \t"0"
            \t{
            \t\t"path"\t\t"C:\\\\Program Files (x86)\\\\Steam"
            \t\t"label"\t\t""
            \t\t"contentid"\t\t"\(randomContentID())"
            \t\t"totalsize"\t\t"0"
            \t\t"apps"
            \t\t{
            \t\t}
            \t}
            \(block.replacingOccurrences(of: "\t\"0\"\n", with: "\t\"1\"\n"))}

            """
        }
        var result = vdf
        result.insert(contentsOf: block, at: close.lowerBound)
        return result
    }

    /// Próxima chave numérica de primeiro nível ("0", "1", …).
    static func nextIndex(in vdf: String) -> Int {
        let pattern = #"(?m)^\t"(\d+)"\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        let range = NSRange(vdf.startIndex..., in: vdf)
        let keys = regex.matches(in: vdf, range: range).compactMap { m in
            Range(m.range(at: 1), in: vdf).flatMap { Int(vdf[$0]) }
        }
        return (keys.max() ?? -1) + 1
    }

    public static func randomContentID() -> String {
        String(UInt64.random(in: 1_000_000_000_000_000...9_000_000_000_000_000_000))
    }
}
