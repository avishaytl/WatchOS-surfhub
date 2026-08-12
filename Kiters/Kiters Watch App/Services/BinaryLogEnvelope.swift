//
//  BinaryLogEnvelope.swift
//  Kiters Watch App
//
//  Binary serialization for every log payload the watch sends to the server.
//
//  The watch never uploads JSON, CSV, or base64-wrapped text anymore — each
//  payload keeps its existing schema (the same named fields, same nesting) but is
//  written as a compact, self-describing binary blob, in the same framing style
//  as the per-session .kslog file (little-endian, length-prefixed, type-tagged).
//
//  This covers BOTH server paths:
//    • CloudSyncService  — diagnostic session-log upload (wraps the raw .kslog)
//    • WatchSessionUploader — start / ping / record / end lifecycle messages
//
//  Container
//  ─────────
//    "KLOG"              4 bytes  magic
//    version             UInt8    = 1
//    flags               UInt8    = 0 (reserved)
//    <value>             the top-level value (always an object)
//
//  Value encoding (type byte + payload) — a binary mirror of JSON value types:
//    0x00 null       (no payload)
//    0x01 bool       UInt8 (0/1)
//    0x02 int        Int64  little-endian
//    0x03 double     Float64 bit pattern, little-endian
//    0x04 string     UInt32 len + UTF-8 bytes
//    0x05 blob       UInt32 len + raw bytes (e.g. the .kslog file, embedded as-is)
//    0x06 array      UInt32 count + each element value
//    0x07 object     UInt32 count + repeated( UInt16 keyLen + key + value )
//
//  Field/key order is preserved, so a decoder reconstructs the original schema
//  one-to-one with no base64 inflation.
//

import Foundation

// MARK: - Value model

indirect enum BinaryLogValue {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case blob(Data)
    case array([BinaryLogValue])
    case object([(String, BinaryLogValue)])

    private enum Tag: UInt8 {
        case null = 0, bool, int, double, string, blob, array, object
    }

    func encode(into data: inout Data) {
        switch self {
        case .null:
            data.append(Tag.null.rawValue)
        case let .bool(b):
            data.append(Tag.bool.rawValue); data.append(b ? 1 : 0)
        case let .int(i):
            data.append(Tag.int.rawValue); data.appendInt64LE(i)
        case let .double(d):
            data.append(Tag.double.rawValue); data.appendUInt64LE(d.bitPattern)
        case let .string(s):
            let b = Data(s.utf8)
            data.append(Tag.string.rawValue); data.appendUInt32LE(UInt32(clamping: b.count)); data.append(b)
        case let .blob(b):
            data.append(Tag.blob.rawValue); data.appendUInt32LE(UInt32(clamping: b.count)); data.append(b)
        case let .array(items):
            data.append(Tag.array.rawValue); data.appendUInt32LE(UInt32(clamping: items.count))
            for item in items { item.encode(into: &data) }
        case let .object(pairs):
            data.append(Tag.object.rawValue); data.appendUInt32LE(UInt32(clamping: pairs.count))
            for (key, value) in pairs {
                let kb = Data(key.utf8)
                data.appendUInt16LE(UInt16(clamping: kb.count)); data.append(kb)
                value.encode(into: &data)
            }
        }
    }

    /// Build a value from a JSON-compatible Swift value (the exact same shapes
    /// the uploaders already hand to JSONSerialization). Order is made
    /// deterministic by sorting object keys.
    static func from(_ any: Any) -> BinaryLogValue {
        switch any {
        case let v as String:           return .string(v)
        case let v as Bool:             return .bool(v)            // (no cross-cast from Int in pure Swift)
        case let v as Int:              return .int(Int64(v))
        case let v as Int64:            return .int(v)
        case let v as Double:           return .double(v)
        case let v as Float:            return .double(Double(v))
        case let v as Data:             return .blob(v)
        case let v as [Any]:            return .array(v.map { from($0) })
        case let v as [String: Any]:    return .object(v.sorted { $0.key < $1.key }.map { ($0.key, from($0.value)) })
        default:                        return .null
        }
    }
}

// MARK: - Envelope (top-level container)

public struct BinaryLogEnvelope {

    enum Field {
        case string(String, String)   // (key, value)
        case blob(String, Data)        // (key, raw bytes)

        var key: String {
            switch self {
            case let .string(k, _): return k
            case let .blob(k, _):   return k
            }
        }

        var value: BinaryLogValue {
            switch self {
            case let .string(_, v): return .string(v)
            case let .blob(_, v):   return .blob(v)
            }
        }
    }

    static let magic = [UInt8]("KLOG".utf8)
    static let version: UInt8 = 1

    let fields: [Field]

    /// Serialize an ordered list of typed fields (used by the diagnostic log upload).
    func encoded() -> Data {
        Self.container(.object(fields.map { ($0.key, $0.value) }))
    }

    /// Serialize an arbitrary JSON-shaped object (used by the lifecycle uploader).
    public static func encode(object: [String: Any]) -> Data {
        container(.from(object))
    }

    private static func container(_ root: BinaryLogValue) -> Data {
        var data = Data()
        data.append(contentsOf: magic)
        data.append(version)
        data.append(0) // flags / reserved
        root.encode(into: &data)
        return data
    }
}

// MARK: - Decoding (tooling / round-trip tests / example viewers)

extension BinaryLogEnvelope {

    /// Decode a KLOG container back into a JSON-compatible object.
    /// Blob values are returned as `Data`. Returns `nil` on malformed input.
    public static func decodeToObject(_ data: Data) -> [String: Any]? {
        let bytes = [UInt8](data)
        var offset = 0
        guard bytes.count >= 6, Array(bytes[0..<4]) == magic else { return nil }
        offset = 4
        guard bytes[offset] == version else { return nil }
        offset += 2 // version + flags
        guard let value = decodeValue(bytes, &offset),
              case let .objectAny(dict) = value else { return nil }
        return dict
    }

    private enum DecodedAny {
        case scalar(Any)
        case objectAny([String: Any])
    }

    private static func decodeValue(_ bytes: [UInt8], _ offset: inout Int) -> DecodedAny? {
        guard offset < bytes.count else { return nil }
        let tag = bytes[offset]; offset += 1
        switch tag {
        case 0: return .scalar(NSNull())
        case 1:
            guard offset < bytes.count else { return nil }
            let b = bytes[offset] != 0; offset += 1; return .scalar(b)
        case 2:
            guard offset + 8 <= bytes.count else { return nil }
            return .scalar(Int(Int64(bitPattern: readUInt64LE(bytes, &offset))))
        case 3:
            guard offset + 8 <= bytes.count else { return nil }
            return .scalar(Double(bitPattern: readUInt64LE(bytes, &offset)))
        case 4:
            guard let d = readLenPrefixed(bytes, &offset) else { return nil }
            return .scalar(String(decoding: d, as: UTF8.self))
        case 5:
            guard let d = readLenPrefixed(bytes, &offset) else { return nil }
            return .scalar(Data(d))
        case 6:
            guard offset + 4 <= bytes.count else { return nil }
            let count = Int(readUInt32LE(bytes, &offset))
            var arr: [Any] = []
            for _ in 0..<count {
                guard let v = decodeValue(bytes, &offset) else { return nil }
                arr.append(flatten(v))
            }
            return .scalar(arr)
        case 7:
            guard offset + 4 <= bytes.count else { return nil }
            let count = Int(readUInt32LE(bytes, &offset))
            var dict: [String: Any] = [:]
            for _ in 0..<count {
                guard offset + 2 <= bytes.count else { return nil }
                let keyLen = Int(readUInt16LE(bytes, &offset))
                guard offset + keyLen <= bytes.count else { return nil }
                let key = String(decoding: bytes[offset..<offset + keyLen], as: UTF8.self)
                offset += keyLen
                guard let v = decodeValue(bytes, &offset) else { return nil }
                dict[key] = flatten(v)
            }
            return .objectAny(dict)
        default:
            return nil
        }
    }

    private static func flatten(_ v: DecodedAny) -> Any {
        switch v {
        case let .scalar(a):    return a
        case let .objectAny(d): return d
        }
    }

    private static func readLenPrefixed(_ bytes: [UInt8], _ offset: inout Int) -> ArraySlice<UInt8>? {
        guard offset + 4 <= bytes.count else { return nil }
        let len = Int(readUInt32LE(bytes, &offset))
        guard offset + len <= bytes.count else { return nil }
        let slice = bytes[offset..<offset + len]
        offset += len
        return slice
    }

    private static func readUInt16LE(_ bytes: [UInt8], _ offset: inout Int) -> UInt16 {
        let v = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        offset += 2; return v
    }

    private static func readUInt32LE(_ bytes: [UInt8], _ offset: inout Int) -> UInt32 {
        let v = UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8) |
                (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
        offset += 4; return v
    }

    private static func readUInt64LE(_ bytes: [UInt8], _ offset: inout Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(bytes[offset + i]) << (8 * i) }
        offset += 8; return v
    }
}

// MARK: - Little-endian append helpers

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        var le = value.littleEndian; Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
    mutating func appendUInt32LE(_ value: UInt32) {
        var le = value.littleEndian; Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
    mutating func appendUInt64LE(_ value: UInt64) {
        var le = value.littleEndian; Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
    mutating func appendInt64LE(_ value: Int64) {
        appendUInt64LE(UInt64(bitPattern: value))
    }
}
