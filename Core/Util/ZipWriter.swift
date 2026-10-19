import Foundation

/// Minimal ZIP writer (files stored uncompressed). Media is already compressed, so storing is
/// as small as deflating would be and needs no extra library. Files are streamed one at a time.
enum ZipWriter {
    struct Entry { let name: String; let url: URL }

    static func write(_ entries: [Entry], to destination: URL) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        var central = Data()
        var offset: UInt32 = 0
        var used = Set<String>()
        let (dosTime, dosDate) = dosDateTime(Date())

        for entry in entries {
            let data = try Data(contentsOf: entry.url, options: .mappedIfSafe)
            guard data.count < Int(UInt32.max) else { continue }
            let name = unique(entry.name, used: &used)
            let nameData = Data(name.utf8)
            let crc = CRC32.checksum(data)
            let size = UInt32(data.count)

            var local = Data()
            local.append(le32: 0x04034b50)
            local.append(le16: 20); local.append(le16: 0x0800)      // version, flags (UTF-8 names)
            local.append(le16: 0)                                    // method: stored
            local.append(le16: dosTime); local.append(le16: dosDate)
            local.append(le32: crc); local.append(le32: size); local.append(le32: size)
            local.append(le16: UInt16(nameData.count)); local.append(le16: 0)
            local.append(nameData)
            out.write(local)
            out.write(data)

            var c = Data()
            c.append(le32: 0x02014b50)
            c.append(le16: 20); c.append(le16: 20); c.append(le16: 0x0800); c.append(le16: 0)
            c.append(le16: dosTime); c.append(le16: dosDate)
            c.append(le32: crc); c.append(le32: size); c.append(le32: size)
            c.append(le16: UInt16(nameData.count)); c.append(le16: 0); c.append(le16: 0)
            c.append(le16: 0); c.append(le16: 0); c.append(le32: 0)
            c.append(le32: offset)
            c.append(nameData)
            central.append(c)
            offset += UInt32(local.count) + size
        }

        var end = Data()
        end.append(le32: 0x06054b50)
        end.append(le16: 0); end.append(le16: 0)
        let count = UInt16(min(entries.count, Int(UInt16.max)))
        end.append(le16: count); end.append(le16: count)
        end.append(le32: UInt32(central.count)); end.append(le32: offset)
        end.append(le16: 0)
        out.write(central)
        out.write(end)
    }

    private static func unique(_ name: String, used: inout Set<String>) -> String {
        var candidate = name, n = 2
        let ext = (name as NSString).pathExtension, base = (name as NSString).deletingPathExtension
        while used.contains(candidate) { candidate = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"; n += 1 }
        used.insert(candidate)
        return candidate
    }

    private static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        let day = UInt16(max(0, (c.year ?? 1980) - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, day)
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for b in buf { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func append(le16 v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func append(le32 v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
}
