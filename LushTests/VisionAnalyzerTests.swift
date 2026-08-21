import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Lush

final class VisionAnalyzerTests: XCTestCase {
    /// The point of handing Vision a bounded image is that the original is
    /// never decoded whole, so the cap is the thing worth pinning: a photo
    /// straight off a phone camera comes back inside it.
    func testBoundedDecodeCapsTheLongEdge() throws {
        let data = try jpeg(width: 4032, height: 3024)
        let image = try XCTUnwrap(VisionAnalyzer.bounded(data))
        XCTAssertEqual(max(image.width, image.height), VisionAnalyzer.maxPixelSize)
        XCTAssertEqual(
            Double(image.width) / Double(image.height),
            4032.0 / 3024.0,
            accuracy: 0.01,
            "the aspect ratio should survive the cap"
        )
    }

    /// Capping is not resizing: something already small enough is left alone
    /// rather than blown up to the cap.
    func testBoundedDecodeLeavesASmallImageAlone() throws {
        let data = try jpeg(width: 320, height: 240)
        let image = try XCTUnwrap(VisionAnalyzer.bounded(data))
        XCTAssertEqual(image.width, 320)
        XCTAssertEqual(image.height, 240)
    }

    func testBoundedDecodeRejectsWhatIsNotAnImage() {
        XCTAssertNil(VisionAnalyzer.bounded(Data("not an image".utf8)))
    }

    private func jpeg(width: Int, height: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        // flat grey: the decode is what's under test, not what it depicts
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())

        let out = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            out,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return out as Data
    }
}
