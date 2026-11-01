import CompanionKit
@testable import DrawMoar
import PencilKit
import XCTest

@MainActor final class EditorTests: XCTestCase {
    func testFitCentersCropAndNewImageResetsZoom() {
        let area = CGSize(width: 402, height: 500)
        let crop = CGRect(x: 2500, y: 1400, width: 1000, height: 500)
        let fit = ImageScrollView.fit(area: area, visible: crop)
        XCTAssertEqual(fit.zoomScale, 0.402, accuracy: 0.0001)
        XCTAssertEqual(fit.contentOffset.x, 1005, accuracy: 0.001)
        XCTAssertEqual(fit.contentOffset.y, 413.3, accuracy: 0.001)

        let scroll = ImageScrollView(frame: CGRect(origin: .zero, size: area))
        let content = UIView(frame: CGRect(origin: .zero, size: crop.size))
        scroll.addSubview(content)
        let delegate = ZoomDelegate(content: content)
        scroll.delegate = delegate
        let first = UIImage()
        let second = UIImage()
        XCTAssertTrue(scroll.prepareImage(first, visible: crop, imageSize: crop.size))
        scroll.fitImage()
        scroll.zoomScale = 1
        XCTAssertTrue(scroll.prepareImage(second, visible: crop, imageSize: crop.size))
        scroll.fitImage()
        XCTAssertEqual(scroll.zoomScale, 0.402, accuracy: 0.0001)
        XCTAssertEqual(scroll.contentOffset.y, -149.5, accuracy: 0.5)
    }

    func testLineWidthPersistsAndPreservesInk() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let model = EditorModel(client: nil, defaults: defaults)
        model.setLineWidth(16)
        XCTAssertEqual(defaults.double(forKey: "lineWidth"), 16)
        let restored = EditorModel(client: nil, defaults: defaults)
        XCTAssertEqual(restored.lineWidth, 16)
        let original = PKInkingTool(.marker, color: .red, width: 4)
        let result = EditorModel.inkingTool(original, width: restored.lineWidth, scale: 0.4)
        XCTAssertEqual(result.inkType, original.inkType)
        XCTAssertEqual(result.color, original.color)
        XCTAssertEqual(result.width, max(6.4, PKInkingTool.InkType.marker.validWidthRange.lowerBound), accuracy: 0.001)
        let pen = EditorModel.inkingTool(PKInkingTool(.pen), width: restored.lineWidth, scale: 0.4)
        XCTAssertEqual(pen.width, 6.4, accuracy: 0.001)
    }

    func testCanvasScaleLimitsLongestSide() {
        for (size, expected) in [(CGSize(width: 5120, height: 2880), CGFloat(0.4)),
                                 (CGSize(width: 1000, height: 500), 1),
                                 (CGSize(width: 8000, height: 1000), 0.256)]
        {
            XCTAssertEqual(EditorModel.canvasScale(for: size), expected, accuracy: 0.0001)
        }
    }

    func testRenderLargeImageAtFullResolution() throws {
        let size = CGSize(width: 5120, height: 2880)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let point = PKStrokePoint(location: CGPoint(x: 1000, y: 560), timeOffset: 0, size: CGSize(width: 8, height: 8), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        let end = PKStrokePoint(location: CGPoint(x: 1004, y: 560), timeOffset: 0.1, size: CGSize(width: 8, height: 8), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        let drawing = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: [point, end], creationDate: Date()))])
        let rendered = try XCTUnwrap(UIImage(data: ImageRenderer.png(image: image, drawing: drawing, crop: nil))?.cgImage)
        XCTAssertEqual(rendered.width, 5120)
        XCTAssertEqual(rendered.height, 2880)
        XCTAssertLessThan(pixel(rendered, x: 2500, y: 1400), 200)
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

    func testEditsDebounceAndUseNewSessionForNextCapture() async throws {
        let client = FakeClient()
        let clock = TestDelay()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let model = EditorModel(client: client, defaults: defaults, delay: { try await clock.wait() })
        await model.activate()
        XCTAssertTrue(client.sessions.isEmpty)
        model.crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        await Task.yield()
        model.crop = CGRect(x: 0, y: 0, width: 2, height: 1)
        await Task.yield()
        model.crop = CGRect(x: 0, y: 0, width: 2, height: 2)
        await Task.yield()
        clock.advance()
        await clock.settle()
        XCTAssertEqual(client.sessions.count, 1)
        XCTAssertEqual(try UIImage(data: XCTUnwrap(client.images.first))?.size, CGSize(width: 2, height: 2))
        await model.newCapture()
        await clock.settle()
        XCTAssertEqual(client.sessions.count, 1)
        model.crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        await Task.yield()
        clock.advance()
        await clock.settle()
        XCTAssertEqual(client.sessions.count, 2)
        guard client.sessions.count == 2 else { return }
        XCTAssertNotEqual(client.sessions[0], client.sessions[1])
    }

    func testEditDuringSendIsSentOnceAfterCompletion() async throws {
        let client = FakeClient()
        client.holdPaste = true
        let clock = TestDelay()
        let model = try EditorModel(client: client, defaults: XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), delay: { try await clock.wait() })
        await model.activate()
        model.crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        await Task.yield()
        clock.advance()
        await clock.settle()
        XCTAssertEqual(client.sessions.count, 1)
        model.crop = CGRect(x: 0, y: 0, width: 2, height: 2)
        await Task.yield()
        clock.advance()
        await clock.settle()
        XCTAssertEqual(client.sessions.count, 1)
        client.finishPaste()
        await clock.settle()
        XCTAssertEqual(client.sessions.count, 2)
        XCTAssertEqual(client.sessions.first, client.sessions.last)
        client.finishPaste()
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

    func testHistoryRestoresEditsAndSendsSelectedCapture() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = FakeClient()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let model = EditorModel(client: client, defaults: defaults, historyDirectory: directory)
        await model.newCapture()
        let first = try XCTUnwrap(model.history.first)
        let point = PKStrokePoint(location: CGPoint(x: 1, y: 1), timeOffset: 0, size: CGSize(width: 1, height: 1), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        model.drawing = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: [point, point], creationDate: Date()))])
        model.applyCrop(CGRect(x: 0, y: 0, width: 1, height: 1))
        let expectedDrawing = model.drawing
        await model.newCapture()
        XCTAssertEqual(model.history.count, 2)
        XCTAssertNotEqual(model.history.first?.id, first.id)
        let restored = EditorModel(client: client, defaults: defaults, historyDirectory: directory)
        let saved = try XCTUnwrap(restored.history.first { $0.id == first.id })
        XCTAssertEqual(saved.drawing.strokes.count, expectedDrawing.strokes.count)
        XCTAssertEqual(saved.drawing.strokes.first?.path.first?.location, expectedDrawing.strokes.first?.path.first?.location)
        XCTAssertEqual(saved.crop, CGRect(x: 0, y: 0, width: 1, height: 1))
        await restored.select(saved)
        XCTAssertEqual(client.sessions, [first.id])
        let expected = try ImageRenderer.png(image: saved.image, drawing: saved.drawing, crop: saved.crop)
        XCTAssertEqual(client.images, [expected])
        restored.deleteHistory(saved)
        XCTAssertNil(restored.image)
        XCTAssertFalse(restored.history.contains { $0.id == saved.id })
        let reloaded = EditorModel(client: nil, defaults: defaults, historyDirectory: directory)
        XCTAssertFalse(reloaded.history.contains { $0.id == saved.id })
    }

    func testHistoryLimitAndCropUndo() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = FakeClient()
        let model = try EditorModel(client: client, defaults: XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), historyDirectory: directory)
        for _ in 0 ..< 31 {
            await model.newCapture()
        }
        XCTAssertEqual(model.history.count, 30)
        let restored = try EditorModel(client: nil, defaults: XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), historyDirectory: directory)
        XCTAssertEqual(restored.history.count, 30)
        let image = try XCTUnwrap(model.image)
        model.applyCrop(CGRect(x: 0, y: 0, width: 1, height: 1))
        let cropped = try XCTUnwrap(UIImage(data: ImageRenderer.png(image: image, drawing: model.drawing, crop: model.crop))?.cgImage)
        XCTAssertEqual(cropped.width, 1)
        XCTAssertTrue(model.undoCrop())
        let original = try XCTUnwrap(UIImage(data: ImageRenderer.png(image: image, drawing: model.drawing, crop: model.crop))?.cgImage)
        XCTAssertEqual(original.width, image.cgImage?.width)
    }

    func testWindowSelectionAndCaptureHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = FakeClient()
        let leaf = WindowFrame(x: 2, y: 2, width: 1, height: 1, app: "Front", title: "Leaf")
        let part = WindowFrame(x: 2, y: 2, width: 2, height: 2, app: "Front", title: "Part", children: [leaf])
        let other = WindowFrame(x: 4, y: 1, width: 1, height: 1, app: "Front", title: "Other")
        client.windows = [
            WindowFrame(x: 1, y: 1, width: 4, height: 4, app: "Front", title: "A", children: [part, other]),
            WindowFrame(x: 3, y: 3, width: 5, height: 5, app: "Back", title: "B"),
        ]
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let model = EditorModel(client: client, defaults: defaults, historyDirectory: directory)
        await model.newCapture()
        XCTAssertEqual(model.windows, client.windows)
        let front = CGRect(x: 1, y: 1, width: 4, height: 4)
        let back = CGRect(x: 3, y: 3, width: 5, height: 5)
        XCTAssertEqual(model.window(at: CGPoint(x: 4, y: 4)), front)
        XCTAssertEqual(model.window(at: CGPoint(x: 7, y: 7)), back)
        XCTAssertNil(model.window(at: CGPoint(x: 9, y: 9)))
        let point = CGPoint(x: 2.5, y: 2.5)
        let partRect = CGRect(x: 2, y: 2, width: 2, height: 2)
        let leafRect = CGRect(x: 2, y: 2, width: 1, height: 1)
        let taps: [(CGPoint, CGRect)] = [
            (point, front), (point, partRect), (point, leafRect), (point, front),
            (CGPoint(x: 4.5, y: 1.5), front),
            (CGPoint(x: 7, y: 7), back), (CGPoint(x: 7, y: 7), back),
            (point, front), (point, partRect),
        ]
        for (location, expected) in taps {
            XCTAssertEqual(model.selectWindow(at: location, confirm: false), expected)
        }
        XCTAssertEqual(model.selectWindow(at: point, confirm: true), partRect)
        XCTAssertEqual(model.crop, partRect)
        XCTAssertTrue(model.undoCrop())
        XCTAssertNil(model.crop)
        model.resetWindowSelection()
        XCTAssertEqual(model.selectWindow(at: point, confirm: true), front)
        let restored = EditorModel(client: nil, defaults: defaults, historyDirectory: directory)
        let entry = try XCTUnwrap(restored.history.first)
        XCTAssertEqual(entry.windows, client.windows)
        await restored.select(entry)
        XCTAssertEqual(restored.windows, client.windows)
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> UInt8 {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes[(y * image.width + x) * 4]
    }
}

@MainActor private final class ZoomDelegate: NSObject, UIScrollViewDelegate {
    let content: UIView

    init(content: UIView) {
        self.content = content
    }

    func viewForZooming(in _: UIScrollView) -> UIView? {
        content
    }
}

@MainActor private final class FakeClient: MacCapturing {
    var captures = 0
    var displayRequests: [UInt32?] = []
    var availableDisplays: [DisplayInfo] = []
    var sessions: [String] = []
    var images: [Data] = []
    var holdPaste = false
    var pendingPaste: CheckedContinuation<Void, Never>?
    var windows: [WindowFrame] = []
    func capture(displayId: UInt32?) async throws -> (png: Data, windows: [WindowFrame]) {
        captures += 1
        displayRequests.append(displayId)
        let png = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in }.pngData()!
        let bytes = try Message.screenshot(png: png, windows: windows).encode()
        var decoder = FrameDecoder()
        guard let frame = try decoder.append(bytes).first,
              case let .screenshot(decoded, frames) = try Message(frame: frame) else { throw MacError.unexpected }
        return (decoded, frames)
    }

    func displays() async throws -> [DisplayInfo] {
        availableDisplays
    }

    func paste(_ data: Data, session: String) async throws {
        sessions.append(session)
        images.append(data)
        if holdPaste {
            await withCheckedContinuation { pendingPaste = $0 }
        }
    }

    func finishPaste() {
        pendingPaste?.resume(); pendingPaste = nil
    }
}

@MainActor private final class TestDelay {
    private var waits: [CheckedContinuation<Void, Error>] = []

    func wait() async throws {
        try await withCheckedThrowingContinuation { waits.append($0) }
    }

    func advance() {
        let pending = waits
        waits.removeAll()
        pending.forEach { $0.resume() }
    }

    func settle() async {
        for _ in 0 ..< 20 {
            await Task.yield()
        }
    }
}
