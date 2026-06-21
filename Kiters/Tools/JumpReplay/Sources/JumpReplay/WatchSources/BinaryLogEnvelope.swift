import Foundation

enum BinaryLogValue {
    case string(String)
    case blob(Data)
    case object([(String, BinaryLogValue)])

    func encode(into data: inout Data) {
        switch self {
        case .string(let value):
            let bytes = Data(value.utf8)
            data.append(4)
            data.appendUInt32LE(UInt32(clamping: bytes.count))
            data.append(bytes)
        case .blob(let value):
            data.append(5)
            data.appendUInt32LE(UInt32(clamping: value.count))
            data.append(value)
        case .object(let fields):
            data.append(7)
            data.appendUInt32LE(UInt32(clamping: fields.count))
            for (key, value) in fields {
                let keyBytes = Data(key.utf8)
                data.appendUInt16LE(UInt16(clamping: keyBytes.count))
                data.append(keyBytes)
                value.encode(into: &data)
            }
        }
    }
}

struct BinaryLogEnvelope {
    enum Field {
        case string(String, String)
        case blob(String, Data)

        var key: String {
            switch self {
            case .string(let key, _), .blob(let key, _): key
            }
        }

        var value: BinaryLogValue {
            switch self {
            case .string(_, let value): .string(value)
            case .blob(_, let value): .blob(value)
            }
        }
    }

    let fields: [Field]

    func encoded() -> Data {
        var data = Data()
        data.append(contentsOf: [UInt8]("KLOG".utf8))
        data.append(1)
        data.append(0)
        BinaryLogValue.object(fields.map { ($0.key, $0.value) }).encode(into: &data)
        return data
    }
}

private extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}
