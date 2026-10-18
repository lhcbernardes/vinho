import Foundation

/// Extrai o ícone principal de um executável PE (.exe/.dll) e devolve um
/// arquivo `.ico` completo (que `NSImage(data:)` entende).
///
/// Caminho: DOS header → PE header → data directory de recursos →
/// árvore de recursos → primeiro `RT_GROUP_ICON` → cada `RT_ICON` referenciado.
public enum PEIconExtractor {
    static let rtIcon: UInt32 = 3
    static let rtGroupIcon: UInt32 = 14

    public static func icoData(fromExecutableAt url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return icoData(fromPE: data)
    }

    public static func icoData(fromPE data: Data) -> Data? {
        let r = ByteReader(data)
        guard r.u16(0) == 0x5A4D, let lfanew = r.u32(0x3C).map(Int.init), r.u32(lfanew) == 0x0000_4550 else {
            return nil
        }

        let coff = lfanew + 4
        guard let sectionCount = r.u16(coff + 2).map(Int.init),
              let optionalSize = r.u16(coff + 16).map(Int.init) else { return nil }
        let optional = coff + 20

        let directoriesOffset: Int
        let directoryCountOffset: Int
        switch r.u16(optional) {
        case 0x10B?: directoriesOffset = 96; directoryCountOffset = 92   // PE32
        case 0x20B?: directoriesOffset = 112; directoryCountOffset = 108 // PE32+
        default: return nil
        }
        // Diretório de recursos é o índice 2 (8 bytes cada).
        guard let directoryCount = r.u32(optional + directoryCountOffset), directoryCount > 2,
              let resourceRVA = r.u32(optional + directoriesOffset + 2 * 8), resourceRVA != 0 else { return nil }

        let sections = readSections(r, table: optional + optionalSize, count: min(sectionCount, 96))
        func offset(ofRVA rva: UInt32) -> Int? {
            for s in sections where rva >= s.virtualAddress && rva < s.virtualAddress &+ s.size {
                return Int(rva - s.virtualAddress) + Int(s.rawPointer)
            }
            return nil
        }

        guard let base = offset(ofRVA: resourceRVA) else { return nil }
        let tree = ResourceTree(reader: r, base: base)

        guard let group = tree.data(type: rtGroupIcon, id: nil),
              let groupOffset = offset(ofRVA: group.rva),
              let groupData = r.bytes(groupOffset, Int(group.size)) else { return nil }

        let g = ByteReader(groupData)
        guard g.u16(2) == 1, let count = g.u16(4).map(Int.init), count > 0 else { return nil }

        struct Image { var header: Data; var payload: Data }
        var images: [Image] = []
        for i in 0..<min(count, 64) {
            let e = 6 + i * 14
            guard let width = g.u8(e), let height = g.u8(e + 1), let colors = g.u8(e + 2),
                  let planes = g.u16(e + 4), let bits = g.u16(e + 6), let id = g.u16(e + 12),
                  let icon = tree.data(type: rtIcon, id: UInt32(id)),
                  let iconOffset = offset(ofRVA: icon.rva),
                  let payload = r.bytes(iconOffset, Int(icon.size)) else { continue }

            var header = Data([width, height, colors, 0])
            header.appendLE(planes)
            header.appendLE(bits)
            images.append(Image(header: header, payload: payload))
        }
        guard !images.isEmpty else { return nil }

        // Monta o .ico: ICONDIR + ICONDIRENTRY[n] + imagens.
        var ico = Data()
        ico.appendLE(UInt16(0))
        ico.appendLE(UInt16(1))
        ico.appendLE(UInt16(images.count))
        var dataOffset = UInt32(6 + 16 * images.count)
        for image in images {
            ico.append(image.header)
            ico.appendLE(UInt32(image.payload.count))
            ico.appendLE(dataOffset)
            dataOffset += UInt32(image.payload.count)
        }
        for image in images { ico.append(image.payload) }
        return ico
    }

    private struct Section { let virtualAddress: UInt32; let size: UInt32; let rawPointer: UInt32 }

    private static func readSections(_ r: ByteReader, table: Int, count: Int) -> [Section] {
        (0..<count).compactMap { i -> Section? in
            let s = table + i * 40
            guard let virtualSize = r.u32(s + 8), let va = r.u32(s + 12),
                  let rawSize = r.u32(s + 16), let raw = r.u32(s + 20) else { return nil }
            return Section(virtualAddress: va, size: max(virtualSize, rawSize), rawPointer: raw)
        }
    }
}

/// Navegação na árvore de recursos (tipo → nome/id → idioma → dados).
struct ResourceTree {
    struct Entry {
        let id: UInt32?   // nil = entrada nomeada (string)
        let offset: UInt32
    }

    let reader: ByteReader
    let base: Int

    func entries(at directory: Int) -> [Entry] {
        guard let named = reader.u16(directory + 12), let ids = reader.u16(directory + 14) else { return [] }
        let count = min(Int(named) + Int(ids), 4096)
        var result: [Entry] = []
        for i in 0..<count {
            let e = directory + 16 + i * 8
            guard let name = reader.u32(e), let offset = reader.u32(e + 4) else { break }
            result.append(Entry(id: name & 0x8000_0000 == 0 ? name & 0xFFFF : nil, offset: offset))
        }
        return result
    }

    func subdirectory(_ entry: Entry) -> Int? {
        entry.offset & 0x8000_0000 != 0 ? base + Int(entry.offset & 0x7FFF_FFFF) : nil
    }

    func dataEntry(_ entry: Entry) -> (rva: UInt32, size: UInt32)? {
        guard entry.offset & 0x8000_0000 == 0 else { return nil }
        let o = base + Int(entry.offset)
        guard let rva = reader.u32(o), let size = reader.u32(o + 4) else { return nil }
        return (rva, size)
    }

    /// Primeiro recurso do tipo (id nil = qualquer), em qualquer idioma.
    func data(type: UInt32, id: UInt32?) -> (rva: UInt32, size: UInt32)? {
        guard let typeEntry = entries(at: base).first(where: { $0.id == type }),
              let typeDir = subdirectory(typeEntry) else { return nil }
        let names = entries(at: typeDir)
        let nameEntry = id == nil ? names.first : names.first(where: { $0.id == id })
        guard let nameEntry, let nameDir = subdirectory(nameEntry),
              let language = entries(at: nameDir).first else { return nil }
        return dataEntry(language)
    }
}
