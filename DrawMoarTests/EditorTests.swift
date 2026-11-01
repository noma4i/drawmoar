import CompanionKit
@testable import DrawMoar
import PencilKit
import XCTest

@MainActor final class EditorTests: XCTestCase {
    func testLineWidthPersistsAndPreservesInk() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let model = EditorModel(client: nil, defaults: defaults)
        model.setLineWidth(16)
        XCTAssertEqual(defaults.double(forKey: "lineWidth"), 16)
        let restored = EditorModel(client: nil, defaults: defaults)
        XCTAssertEqual(restored.lineWidth, 16)
        let original = PKInkingTool(.marker, color: .red, width: 4)
        let result = EditorModel.inkingTool(original, width: restored.lineWidth)
        XCTAssertEqual(result.inkType, original.inkType)
        XCTAssertEqual(result.color, original.color)
        XCTAssertEqual(result.width, 16, accuracy: 0.001)
    }

    func testRenderAndCropPreservePixelsAndStroke() throws {
        var result: Result<Void, Error>!
        UITraitCollection(userInterfaceStyle: .dark).performAsCurrent {
            result = Result { try checkRenderAndCrop() }
        }
        try result.get()
    }

    private func checkRenderAndCrop() throws {
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

    func testActivateCapturesOnlyWithoutEdits() async throws {
        let client = FakeClient()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let model = EditorModel(client: client, defaults: defaults)
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

    func testSelectedDisplayIsPersistedAndMissingDisplayFallsBackToAuto() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let client = FakeClient()
        client.availableDisplays = [DisplayInfo(id: 7, name: "Screen", width: 100, height: 100, isMain: true)]
        let settings = EditorModel(client: client, defaults: defaults)
        settings.selectedDisplay = 7
        let model = EditorModel(client: client, defaults: defaults)
        await model.activate()
        XCTAssertEqual(client.displayRequests, [7])
        model.selectedDisplay = nil
        await model.activate()
        XCTAssertEqual(client.displayRequests, [7, nil])
        model.selectedDisplay = 7
        client.availableDisplays = []
        await model.activate()
        XCTAssertEqual(client.displayRequests, [7, nil, nil])
        XCTAssertNil(defaults.object(forKey: "displayId"))
    }

    func testForgetMacDeletesPairingAndRequiresPairing() throws {
        let pair = Pairing(deviceId: "device", key: Data([1]), macName: "Mac")
        var stored: Pairing? = pair
        let model = try EditorModel(client: FakeClient(), pairing: pair, defaults: XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), deletePairing: { stored = nil })
        model.forgetMac()
        XCTAssertNil(stored)
        XCTAssertNil(model.pairing)
        XCTAssertNil(model.client)
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> UInt8 {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes[(y * image.width + x) * 4]
    }
}

@MainActor private final class FakeClient: MacCapturing {
    var captures = 0
    var displayRequests: [UInt32?] = []
    var availableDisplays: [DisplayInfo] = []
    func capture(displayId: UInt32?) async throws -> Data {
        captures += 1
        displayRequests.append(displayId)
        return UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in }.pngData()!
    }

    func displays() async throws -> [DisplayInfo] {
        availableDisplays
    }

    func paste(_: Data) async throws {}
}
