import CompanionKit
@testable import DrawMoar
import PencilKit
import XCTest

@MainActor final class EditorTests: XCTestCase {
    func testRenderAndCropPreservePixelsAndStroke() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 200), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        }
        let point = PKStrokePoint(location: CGPoint(x: 150, y: 80), timeOffset: 0, size: CGSize(width: 20, height: 20), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        let end = PKStrokePoint(location: CGPoint(x: 160, y: 80), timeOffset: 0.1, size: CGSize(width: 20, height: 20), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        let path = PKStrokePath(controlPoints: [point, end], creationDate: Date())
        let drawing = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: path)])
        let full = try XCTUnwrap(UIImage(data: ImageRenderer.png(image: image, drawing: drawing, crop: nil))?.cgImage)
        XCTAssertEqual(full.width, 400)
        XCTAssertEqual(full.height, 200)
        XCTAssertLessThan(pixel(full, x: 150, y: 80), 200)
        XCTAssertEqual(pixel(full, x: 20, y: 20), 255)
        let cropped = try XCTUnwrap(UIImage(data: ImageRenderer.png(image: image, drawing: drawing, crop: CGRect(x: 100, y: 50, width: 200, height: 100)))?.cgImage)
        XCTAssertEqual(cropped.width, 200)
        XCTAssertEqual(cropped.height, 100)
        XCTAssertLessThan(pixel(cropped, x: 50, y: 30), 200)
    }

    func testActivateCapturesOnlyWithoutEdits() async {
        let client = FakeClient()
        let model = EditorModel(client: client)
        await model.activate()
        XCTAssertEqual(client.captures, 1)
        let point = PKStrokePoint(location: CGPoint(x: 1, y: 1), timeOffset: 0, size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        model.drawing = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: [point, point], creationDate: Date()))])
        await model.activate()
        XCTAssertEqual(client.captures, 1)
        model.drawing = PKDrawing()
        model.crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        await model.activate()
        XCTAssertEqual(client.captures, 1)
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> UInt8 {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes[((image.height - 1 - y) * image.width + x) * 4]
    }
}

@MainActor private final class FakeClient: MacCapturing {
    var captures = 0
    func capture(displayId _: UInt32?) async throws -> Data {
        captures += 1
        return UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in }.pngData()!
    }

    func displays() async throws -> [DisplayInfo] {
        []
    }

    func paste(_: Data) async throws {}
}
