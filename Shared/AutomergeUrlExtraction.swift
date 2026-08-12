import Foundation
import CryptoKit

struct ExtractedAutomergeUrl: Equatable {
    let url: String
    let heads: [String]

    var display: String {
        heads.isEmpty ? url : "\(url)#\(heads.joined(separator: "|"))"
    }
}

enum AutomergeUrlExtraction {
    static func extract(from input: String) -> ExtractedAutomergeUrl? {
        if let found = scan(input) { return found }
        if let decoded = input.removingPercentEncoding, decoded != input {
            return scan(decoded)
        }
        return nil
    }

    private static let pattern =
        /automerge:([1-9A-HJ-NP-Za-km-z]{22,32})(?:#([1-9A-HJ-NP-Za-km-z|]+))?/

    private static func scan(_ string: String) -> ExtractedAutomergeUrl? {
        for match in string.matches(of: pattern) {
            guard base58CheckPayload(String(match.1))?.count == 16 else { continue }
            var heads: [String] = []
            if let section = match.2 {
                let parts = section.split(separator: "|").map(String.init)
                if parts.allSatisfy({ base58CheckPayload($0)?.count == 32 }) {
                    heads = parts
                }
            }
            return ExtractedAutomergeUrl(url: "automerge:\(match.1)", heads: heads)
        }
        return nil
    }

    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")

    private static func base58CheckPayload(_ string: String) -> Data? {
        var bytes: [UInt8] = []
        for character in string {
            guard let digit = alphabet.firstIndex(of: character) else { return nil }
            var carry = digit
            for i in bytes.indices.reversed() {
                carry += Int(bytes[i]) * 58
                bytes[i] = UInt8(carry & 0xff)
                carry >>= 8
            }
            while carry > 0 {
                bytes.insert(UInt8(carry & 0xff), at: 0)
                carry >>= 8
            }
        }
        for character in string {
            guard character == "1" else { break }
            bytes.insert(0, at: 0)
        }
        guard bytes.count > 4 else { return nil }
        let payload = Data(bytes.prefix(bytes.count - 4))
        let check = Data(bytes.suffix(4))
        let digest = SHA256.hash(data: Data(SHA256.hash(data: payload)))
        guard Data(digest.prefix(4)) == check else { return nil }
        return payload
    }
}
