import Foundation
import XCTest
@testable import Lush

#if os(macOS)
final class HTTPRequestTests: XCTestCase {
    func testParsesRequestTargetHeadersAndExactBody() throws {
        let data = request(
            "POST /v1/note?url=automerge%3Aabc&tag=one&tag=two HTTP/1.1\r\nAuthorization: Bearer token\r\nContent-Type: application/json\r\nContent-Length: 12\r\n\r\n{\"name\":\"x\"}ignored"
        )
        let parsed = try XCTUnwrap(HTTPRequest(data: data))
        XCTAssertEqual(parsed.method, "POST")
        XCTAssertEqual(parsed.path, "/v1/note")
        XCTAssertEqual(parsed.query, ["url": "automerge:abc", "tag": "one"])
        XCTAssertEqual(parsed.authorization, "Bearer token")
        XCTAssertEqual(parsed.body, Data("{\"name\":\"x\"}".utf8))
        XCTAssertEqual(try parsed.jsonBody()["name"] as? String, "x")
    }

    func testHeaderNamesAreCaseInsensitive() throws {
        let parsed = try XCTUnwrap(HTTPRequest(data: request(
            "POST / HTTP/1.1\r\ncOnTeNt-LeNgTh: 2\r\naUtHoRiZaTiOn: value\r\n\r\n{}"
        )))
        XCTAssertEqual(parsed.authorization, "value")
        XCTAssertEqual(parsed.body, Data("{}".utf8))
    }

    func testToleratesUnparseableContentLengths() throws {
        let values = ["", "1x", "１２", "999999999999999999999999999999999999"]
        for value in values {
            let parsed = try XCTUnwrap(HTTPRequest(data: request(
                "POST / HTTP/1.1\r\nContent-Length: \(value)\r\n\r\nx"
            )), "Rejected Content-Length: \(value)")
            XCTAssertEqual(parsed.body, Data(), "Non-empty body for Content-Length: \(value)")
        }
    }

    func testRejectsOutOfRangeContentLengths() {
        for value in ["-1", "1048577"] {
            XCTAssertNil(HTTPRequest(data: request(
                "POST / HTTP/1.1\r\nContent-Length: \(value)\r\n\r\nx"
            )), "Accepted Content-Length: \(value)")
        }
    }

    func testAcceptsDuplicateHeadersLastValueWins() throws {
        let lengths = try XCTUnwrap(HTTPRequest(data: request(
            "POST / HTTP/1.1\r\nContent-Length: 0\r\ncontent-length: 1\r\n\r\nx"
        )))
        XCTAssertEqual(lengths.body, Data("x".utf8))

        let authorizations = try XCTUnwrap(HTTPRequest(data: request(
            "GET / HTTP/1.1\r\nAuthorization: first\r\nauthorization: second\r\n\r\n"
        )))
        XCTAssertEqual(authorizations.authorization, "second")
    }

    func testHeaderLinesWithoutColonsAreMalformed() {
        let corpus = [
            "GET / HTTP/1.1\r\nNoColonHere\r\n\r\n",
            "GET / HTTP/1.1\r\nAuthorization: ok\r\n \r\n\r\n",
            "GET / HTTP/1.1\r\n: nameless\r\n\r\n",
        ]
        for string in corpus {
            guard case .malformed = HTTPRequest.parse(request(string)) else {
                return XCTFail("Accepted header block: \(string.debugDescription)")
            }
        }
    }

    func testIncompleteRequestsNeedMoreData() {
        let corpus: [Data] = [
            Data(),
            request("GET / HTTP/1.1\r\n"),
            request("POST / HTTP/1.1\r\nContent-Length: 2\r\n\r\nx"),
        ]
        for data in corpus {
            guard case .needMoreData = HTTPRequest.parse(data) else {
                return XCTFail("Expected needMoreData for \(data)")
            }
        }
    }

    func testRejectsMalformedRequests() {
        let corpus: [Data] = [
            request("GET\r\n\r\n"),
            request("GET % HTTP/1.1\r\n\r\n"),
            Data([0x47, 0x45, 0x54, 0x20, 0x2F, 0x20, 0xFF, 0x0D, 0x0A, 0x0D, 0x0A]),
        ]
        for data in corpus {
            guard case .malformed = HTTPRequest.parse(data) else {
                return XCTFail("Expected malformed for \(data)")
            }
            XCTAssertNil(HTTPRequest(data: data))
        }
    }

    func testJSONBodyRequiresAnObject() throws {
        let array = try XCTUnwrap(HTTPRequest(data: request(
            "POST / HTTP/1.1\r\nContent-Length: 2\r\n\r\n[]"
        )))
        XCTAssertThrowsError(try array.jsonBody())

        let invalid = try XCTUnwrap(HTTPRequest(data: request(
            "POST / HTTP/1.1\r\nContent-Length: 1\r\n\r\n{"
        )))
        XCTAssertThrowsError(try invalid.jsonBody())
    }

    func testResponseContentLengthMatchesBody() throws {
        let response = HTTPResponse.json(status: 201, value: ["ok": true]).data
        let separator = Data("\r\n\r\n".utf8)
        let boundary = try XCTUnwrap(response.range(of: separator))
        let header = try XCTUnwrap(String(data: response[..<boundary.lowerBound], encoding: .utf8))
        let body = response[boundary.upperBound...]
        XCTAssertTrue(header.hasPrefix("HTTP/1.1 201 Created\r\n"))
        XCTAssertTrue(header.contains("Content-Length: \(body.count)\r\n"))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: Bool], ["ok": true])
    }

    func testDeterministicParserMutationCorpus() {
        var random = HTTPRandom(seed: 0x4854_5450_4655_5A5A)
        let seed = Array("POST /v1/note?url=x HTTP/1.1\r\nAuthorization: Bearer token\r\nContent-Length: 13\r\n\r\n{\"name\":\"x\"}".utf8)
        for _ in 0..<50_000 {
            var bytes = seed
            let mutations = 1 + Int(random.next() % 8)
            for _ in 0..<mutations {
                switch random.next() % 3 {
                case 0 where !bytes.isEmpty:
                    bytes.remove(at: Int(random.next() % UInt64(bytes.count)))
                case 1 where !bytes.isEmpty:
                    bytes[Int(random.next() % UInt64(bytes.count))] = UInt8(truncatingIfNeeded: random.next())
                default:
                    let index = Int(random.next() % UInt64(bytes.count + 1))
                    bytes.insert(UInt8(truncatingIfNeeded: random.next()), at: index)
                }
            }
            _ = HTTPRequest(data: Data(bytes))
        }
    }

    private func request(_ string: String) -> Data {
        Data(string.utf8)
    }
}

private struct HTTPRandom {
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
#endif
