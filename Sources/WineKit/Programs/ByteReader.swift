import Foundation

/// Leitura little-endian com checagem de limites sobre `Data` (pode ser
/// memory-mapped: executáveis de jogos chegam a GBs e não são copiados).
struct ByteReader {
    let data: Data

    init(_ data: Data) { self.data = data }

    var count: Int { data.count }

    func u8(_ offset: Int) -> UInt8? {
        guard offset >= 0, offset < data.count else { return nil }
        return data[data.startIndex + offset]
    }

    func u16(_ offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        let i = data.startIndex + offset
        return UInt16(data[i]) | UInt16(data[i + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let i = data.startIndex + offset
        return UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
    }

    func bytes(_ offset: Int, _ length: Int) -> Data? {
        guard offset >= 0, length >= 0, offset + length <= data.count else { return nil }
        let i = data.startIndex + offset
        return data.subdata(in: i..<(i + length))
    }

    /// String ANSI/Latin-1 terminada em zero.
    func cString(_ offset: Int, maxLength: Int = 1024) -> String? {
        var bytes: [UInt8] = []
        var o = offset
        while let b = u8(o), b != 0, bytes.count < maxLength {
            bytes.append(b)
            o += 1
        }
        guard u8(o) != nil else { return nil }
        return String(bytes: bytes, encoding: .isoLatin1)
    }

    /// String UTF-16LE terminada em zero.
    func utf16CString(_ offset: Int, maxLength: Int = 1024) -> String? {
        var units: [UInt16] = []
        var o = offset
        while let u = u16(o), u != 0, units.count < maxLength {
            units.append(u)
            o += 2
        }
        guard u16(o) != nil else { return nil }
        return String(decoding: units, as: UTF16.self)
    }

    func utf16(_ offset: Int, count: Int) -> String? {
        var units: [UInt16] = []
        units.reserveCapacity(count)
        for i in 0..<count {
            guard let u = u16(offset + i * 2) else { return nil }
            units.append(u)
        }
        return String(decoding: units, as: UTF16.self)
    }

    func latin1(_ offset: Int, count: Int) -> String? {
        guard let d = bytes(offset, count) else { return nil }
        return String(data: d, encoding: .isoLatin1)
    }
}

extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func appendLE(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { append(UInt8((value >> UInt32(shift)) & 0xFF)) }
    }
}
