import Foundation

/// Just enough CBOR for automerge-repo's ephemeral envelope and presence
/// messages — plain maps, no record tags, matching cbor-x with
/// useRecords: false.
enum CBOR {
    indirect enum Value {
        case uint(UInt64)
        case negint(Int64)
        case bytes(Data)
        case string(String)
        case array([Value])
        case map([(String, Value)])
        case bool(Bool)
        case null
        case undefined
        case double(Double)

        subscript(key: String) -> Value? {
            guard case .map(let pairs) = self else { return nil }
            return pairs.first { $0.0 == key }?.1
        }

        var stringValue: String? {
            if case .string(let s) = self { return s }
            return nil
        }

        var bytesValue: Data? {
            if case .bytes(let d) = self { return d }
            return nil
        }

        var boolValue: Bool? {
            if case .bool(let b) = self { return b }
            return nil
        }

        var uintValue: UInt64? {
            switch self {
            case .uint(let n): return n
            case .double(let d) where d >= 0: return UInt64(d)
            default: return nil
            }
        }

        var doubleValue: Double? {
            switch self {
            case .double(let d): return d
            case .uint(let n): return Double(n)
            case .negint(let n): return Double(n)
            default: return nil
            }
        }
    }

    enum DecodeError: Error {
        case truncated
        case unsupported(UInt8)
        case invalidString
        case nonStringKey
    }

    // MARK: encode

    static func encode(_ value: Value) -> Data {
        var out = Data()
        write(value, into: &out)
        return out
    }

    private static func writeHead(major: UInt8, length: UInt64, into out: inout Data) {
        let m = major << 5
        switch length {
        case 0..<24:
            out.append(m | UInt8(length))
        case 24...UInt64(UInt8.max):
            out.append(m | 24)
            out.append(UInt8(length))
        case ...UInt64(UInt16.max):
            out.append(m | 25)
            withUnsafeBytes(of: UInt16(length).bigEndian) { out.append(contentsOf: $0) }
        case ...UInt64(UInt32.max):
            out.append(m | 26)
            withUnsafeBytes(of: UInt32(length).bigEndian) { out.append(contentsOf: $0) }
        default:
            out.append(m | 27)
            withUnsafeBytes(of: length.bigEndian) { out.append(contentsOf: $0) }
        }
    }

    private static func write(_ value: Value, into out: inout Data) {
        switch value {
        case .uint(let n):
            writeHead(major: 0, length: n, into: &out)
        case .negint(let n):
            writeHead(major: 1, length: UInt64(-1 - n), into: &out)
        case .bytes(let data):
            writeHead(major: 2, length: UInt64(data.count), into: &out)
            out.append(data)
        case .string(let string):
            let utf8 = Data(string.utf8)
            writeHead(major: 3, length: UInt64(utf8.count), into: &out)
            out.append(utf8)
        case .array(let items):
            writeHead(major: 4, length: UInt64(items.count), into: &out)
            for item in items { write(item, into: &out) }
        case .map(let pairs):
            writeHead(major: 5, length: UInt64(pairs.count), into: &out)
            for (key, item) in pairs {
                write(.string(key), into: &out)
                write(item, into: &out)
            }
        case .bool(let b):
            out.append(b ? 0xF5 : 0xF4)
        case .null:
            out.append(0xF6)
        case .undefined:
            out.append(0xF7)
        case .double(let d):
            out.append(0xFB)
            withUnsafeBytes(of: d.bitPattern.bigEndian) { out.append(contentsOf: $0) }
        }
    }

    // MARK: decode

    static func decode(_ data: Data) throws -> Value {
        var cursor = data.startIndex
        return try read(data, &cursor, depth: 0)
    }

    private static let maxDepth = 32

    private static func byte(_ data: Data, _ cursor: inout Data.Index) throws -> UInt8 {
        guard cursor < data.endIndex else { throw DecodeError.truncated }
        let b = data[cursor]
        cursor = data.index(after: cursor)
        return b
    }

    private static func readLength(_ info: UInt8, _ data: Data, _ cursor: inout Data.Index) throws -> UInt64 {
        switch info {
        case 0..<24: return UInt64(info)
        case 24: return UInt64(try byte(data, &cursor))
        case 25:
            var value: UInt64 = 0
            for _ in 0..<2 { value = value << 8 | UInt64(try byte(data, &cursor)) }
            return value
        case 26:
            var value: UInt64 = 0
            for _ in 0..<4 { value = value << 8 | UInt64(try byte(data, &cursor)) }
            return value
        case 27:
            var value: UInt64 = 0
            for _ in 0..<8 { value = value << 8 | UInt64(try byte(data, &cursor)) }
            return value
        default:
            throw DecodeError.unsupported(info)
        }
    }

    private static func read(_ data: Data, _ cursor: inout Data.Index, depth: Int) throws -> Value {
        guard depth < maxDepth else { throw DecodeError.truncated }
        let head = try byte(data, &cursor)
        let major = head >> 5
        let info = head & 0x1F
        switch major {
        case 0:
            return .uint(try readLength(info, data, &cursor))
        case 1:
            return .negint(-1 - Int64(try readLength(info, data, &cursor)))
        case 2:
            let declared = try readLength(info, data, &cursor)
            guard declared <= UInt64(data.distance(from: cursor, to: data.endIndex)) else { throw DecodeError.truncated }
            let length = Int(declared)
            let slice = Data(data[cursor..<data.index(cursor, offsetBy: length)])
            cursor = data.index(cursor, offsetBy: length)
            return .bytes(slice)
        case 3:
            let declared = try readLength(info, data, &cursor)
            guard declared <= UInt64(data.distance(from: cursor, to: data.endIndex)) else { throw DecodeError.truncated }
            let length = Int(declared)
            let slice = data[cursor..<data.index(cursor, offsetBy: length)]
            cursor = data.index(cursor, offsetBy: length)
            guard let string = String(data: slice, encoding: .utf8) else { throw DecodeError.invalidString }
            return .string(string)
        case 4:
            let declared = try readLength(info, data, &cursor)
            // every element takes at least one byte; a hostile length can't
            // be allowed to drive allocation
            guard declared <= UInt64(data.distance(from: cursor, to: data.endIndex)) else {
                throw DecodeError.truncated
            }
            let length = Int(declared)
            var items: [Value] = []
            items.reserveCapacity(length)
            for _ in 0..<length { items.append(try read(data, &cursor, depth: depth + 1)) }
            return .array(items)
        case 5:
            let declared = try readLength(info, data, &cursor)
            guard declared <= UInt64(data.distance(from: cursor, to: data.endIndex)) / 2 + 1 else {
                throw DecodeError.truncated
            }
            let length = Int(declared)
            var pairs: [(String, Value)] = []
            pairs.reserveCapacity(length)
            for _ in 0..<length {
                guard case .string(let key) = try read(data, &cursor, depth: depth + 1) else { throw DecodeError.nonStringKey }
                pairs.append((key, try read(data, &cursor, depth: depth + 1)))
            }
            return .map(pairs)
        case 6:
            _ = try readLength(info, data, &cursor)
            return try read(data, &cursor, depth: depth + 1)
        case 7:
            switch info {
            case 20: return .bool(false)
            case 21: return .bool(true)
            case 22: return .null
            case 23: return .undefined
            case 25:
                var bits: UInt16 = 0
                for _ in 0..<2 { bits = bits << 8 | UInt16(try byte(data, &cursor)) }
                return .double(Double(Float16(bitPattern: bits)))
            case 26:
                var bits: UInt32 = 0
                for _ in 0..<4 { bits = bits << 8 | UInt32(try byte(data, &cursor)) }
                return .double(Double(Float(bitPattern: bits)))
            case 27:
                var bits: UInt64 = 0
                for _ in 0..<8 { bits = bits << 8 | UInt64(try byte(data, &cursor)) }
                return .double(Double(bitPattern: bits))
            default:
                throw DecodeError.unsupported(head)
            }
        default:
            throw DecodeError.unsupported(head)
        }
    }
}
