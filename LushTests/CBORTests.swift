import Foundation
import XCTest
@testable import Lush

final class CBORTests: XCTestCase {
    func testIntegerBounds() throws {
        let maximumUnsigned = Data([0x1B, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        guard case .uint(let unsigned) = try CBOR.decode(maximumUnsigned) else {
            return XCTFail("Expected an unsigned integer")
        }
        XCTAssertEqual(unsigned, UInt64.max)

        let minimumSigned = Data([0x3B, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        guard case .negint(let signed) = try CBOR.decode(minimumSigned) else {
            return XCTFail("Expected a negative integer")
        }
        XCTAssertEqual(signed, Int64.min)

        assertIntegerOutOfRange(Data([0x3B, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]))
        assertIntegerOutOfRange(Data([0x3B, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]))
    }

    func testDoubleToUnsignedBounds() {
        let twoTo64 = Double(sign: .plus, exponent: 64, significand: 1)
        XCTAssertEqual(CBOR.Value.double(0).uintValue, 0)
        XCTAssertEqual(CBOR.Value.double(1.75).uintValue, 1)
        XCTAssertEqual(CBOR.Value.double(twoTo64.nextDown).uintValue, UInt64.max - 2_047)
        XCTAssertNil(CBOR.Value.double(-1).uintValue)
        XCTAssertNil(CBOR.Value.double(twoTo64).uintValue)
        XCTAssertNil(CBOR.Value.double(.infinity).uintValue)
        XCTAssertNil(CBOR.Value.double(-.infinity).uintValue)
        XCTAssertNil(CBOR.Value.double(.nan).uintValue)
    }

    func testDeclaredLengthsCannotAllocatePastInput() {
        let oversizedHeads: [[UInt8]] = [
            [0x5B, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
            [0x7B, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
            [0x9B, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
            [0xBB, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
        ]
        for bytes in oversizedHeads {
            XCTAssertThrowsError(try CBOR.decode(Data(bytes)))
        }
    }

    func testMalformedCorpusIsRejected() {
        let corpus: [[UInt8]] = [
            [],
            [0x18],
            [0x19, 0x00],
            [0x1A, 0x00, 0x00, 0x00],
            [0x1B, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
            [0x42, 0x01],
            [0x62, 0xC3, 0x28],
            [0x81],
            [0xA1, 0x01, 0x02],
            [0xA1, 0x61, 0x61],
            [0xC0],
            [0xF9, 0x00],
            [0xFA, 0x00, 0x00, 0x00],
            [0xFB, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
            [0x5F],
            [0x7F],
            [0x9F],
            [0xBF],
            [0xFF],
        ]
        for bytes in corpus {
            XCTAssertThrowsError(try CBOR.decode(Data(bytes)), "Accepted \(bytes)")
        }
    }

    func testEveryTruncationOfCompositeValueIsRejected() {
        let value = CBOR.Value.map([
            ("bytes", .bytes(Data((0...64).map(UInt8.init)))),
            ("nested", .array([.string("hello"), .uint(UInt64.max), .bool(true)])),
            ("double", .double(.pi)),
        ])
        let encoded = CBOR.encode(value)
        for length in 0..<encoded.count {
            XCTAssertThrowsError(try CBOR.decode(encoded.prefix(length)), "Accepted prefix of length \(length)")
        }
        XCTAssertNoThrow(try CBOR.decode(encoded))
    }

    func testNestingLimit() {
        var accepted = Data(repeating: 0x81, count: 31)
        accepted.append(0)
        XCTAssertNoThrow(try CBOR.decode(accepted))

        var rejected = Data(repeating: 0x81, count: 32)
        rejected.append(0)
        XCTAssertThrowsError(try CBOR.decode(rejected))
    }

    func testFloatWidths() throws {
        XCTAssertEqual(try decodedDouble([0xF9, 0x3C, 0x00]), 1)
        XCTAssertEqual(try decodedDouble([0xF9, 0x00, 0x01]), 0x1p-24)
        XCTAssertEqual(try decodedDouble([0xFA, 0x3F, 0x80, 0x00, 0x00]), 1)
        XCTAssertEqual(try decodedDouble([0xFB, 0x3F, 0xF0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]), 1)
        XCTAssertTrue(try decodedDouble([0xF9, 0x7E, 0x00]).isNaN)
        XCTAssertEqual(try decodedDouble([0xF9, 0xFC, 0x00]), -.infinity)
    }

    func testGeneratedValuesRoundTripCanonically() throws {
        var random = SplitMix64(seed: 0xC0B0_5EED_F00D_BAAD)
        for _ in 0..<20_000 {
            let value = generatedValue(random: &random, depth: 0)
            let encoded = CBOR.encode(value)
            let decoded = try CBOR.decode(encoded)
            XCTAssertEqual(CBOR.encode(decoded), encoded)
        }
    }

    func testDeterministicRandomByteCorpusDoesNotCrash() {
        var random = SplitMix64(seed: 0xD15E_A5ED_CAFE_BEEF)
        for _ in 0..<100_000 {
            let length = Int(random.next() % 257)
            var bytes = [UInt8]()
            bytes.reserveCapacity(length)
            for _ in 0..<length {
                bytes.append(UInt8(truncatingIfNeeded: random.next()))
            }
            _ = try? CBOR.decode(Data(bytes))
        }
    }

    private func assertIntegerOutOfRange(
        _ data: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try CBOR.decode(data), file: file, line: line) { error in
            guard case CBOR.DecodeError.integerOutOfRange = error else {
                return XCTFail("Expected integerOutOfRange, got \(error)", file: file, line: line)
            }
        }
    }

    private func decodedDouble(_ bytes: [UInt8]) throws -> Double {
        guard case .double(let value) = try CBOR.decode(Data(bytes)) else {
            throw TestFailure.unexpectedValue
        }
        return value
    }

    private func generatedValue(random: inout SplitMix64, depth: Int) -> CBOR.Value {
        let choice = depth >= 5 ? Int(random.next() % 9) : Int(random.next() % 12)
        switch choice {
        case 0:
            return .uint(random.next())
        case 1:
            return .negint(-1 - Int64(random.next() & UInt64(Int64.max)))
        case 2:
            let count = Int(random.next() % 33)
            return .bytes(Data((0..<count).map { _ in UInt8(truncatingIfNeeded: random.next()) }))
        case 3:
            let count = Int(random.next() % 33)
            let scalars = (0..<count).map { _ in UnicodeScalar(32 + Int(random.next() % 95))! }
            return .string(String(String.UnicodeScalarView(scalars)))
        case 4:
            return .bool(random.next() & 1 == 0)
        case 5:
            return .null
        case 6:
            return .undefined
        case 7:
            return .double(Double(bitPattern: random.next()))
        case 8:
            return .double(Double(Int64(bitPattern: random.next()) % 1_000_000) / 10)
        case 9:
            let count = Int(random.next() % 5)
            return .array((0..<count).map { _ in generatedValue(random: &random, depth: depth + 1) })
        default:
            let count = Int(random.next() % 5)
            let pairs = (0..<count).map { index in
                ("k\(depth)-\(index)", generatedValue(random: &random, depth: depth + 1))
            }
            return .map(pairs)
        }
    }
}

private enum TestFailure: Error {
    case unexpectedValue
}

private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
