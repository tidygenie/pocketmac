import Foundation

/// Tiny big-endian binary writer used for every PocketMac message.
struct WireWriter {
    private(set) var data = Data()

    init(capacity: Int = 64) { data.reserveCapacity(capacity) }

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func bool(_ v: Bool) { data.append(v ? 1 : 0) }
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func i8(_ v: Int8) { u8(UInt8(bitPattern: v)) }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func raw(_ d: Data) { data.append(d) }
    mutating func blob16(_ d: Data) {
        let d = d.prefix(Int(UInt16.max))
        u16(UInt16(d.count)); data.append(d)
    }
    mutating func blob32(_ d: Data) { u32(UInt32(d.count)); data.append(d) }
    mutating func string(_ s: String) { blob16(Data(s.utf8)) }
    mutating func longString(_ s: String) { blob32(Data(s.utf8)) }
}

struct WireError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// Matching reader. Throws on truncated / malformed input instead of crashing.
struct WireReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    var remainingCount: Int { data.endIndex - offset }

    mutating func take(_ n: Int) throws -> Data {
        guard n >= 0, remainingCount >= n else { throw WireError("truncated message") }
        let d = data.subdata(in: offset..<(offset + n))
        offset += n
        return d
    }

    mutating func rest() -> Data {
        let d = data.subdata(in: offset..<data.endIndex)
        offset = data.endIndex
        return d
    }

    private mutating func int<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let size = MemoryLayout<T>.size
        guard remainingCount >= size else { throw WireError("truncated message") }
        var v: T = 0
        for i in 0..<size { v = (v << 8) | T(data[offset + i]) }
        offset += size
        return v
    }

    mutating func u8() throws -> UInt8 { try int(UInt8.self) }
    mutating func bool() throws -> Bool { try u8() != 0 }
    mutating func u16() throws -> UInt16 { try int(UInt16.self) }
    mutating func u32() throws -> UInt32 { try int(UInt32.self) }
    mutating func u64() throws -> UInt64 { try int(UInt64.self) }
    mutating func i8() throws -> Int8 { Int8(bitPattern: try u8()) }
    mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
    mutating func blob16() throws -> Data { try take(Int(try u16())) }
    mutating func blob32() throws -> Data { try take(Int(try u32())) }
    mutating func string() throws -> String { String(decoding: try blob16(), as: UTF8.self) }
    mutating func longString() throws -> String { String(decoding: try blob32(), as: UTF8.self) }
}
