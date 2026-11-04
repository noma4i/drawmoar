import CompanionKit
@testable import DrawMoar
import ImageIO
import PencilKit
import SwiftUI
import XCTest

@MainActor final class EditorTests: XCTestCase {
    func testToolRowWidthSubtractsSideList() {
        XCTAssertEqual(EditorLayoutPolicy.toolRowWidth(containerWidth: 1000, sideListShown: false), 1000)
        XCTAssertEqual(EditorLayoutPolicy.toolRowWidth(containerWidth: 1000, sideListShown: true), 719)
        XCTAssertEqual(ToolRowLayout.layout(forWidth: EditorLayoutPolicy.toolRowWidth(containerWidth: 1000, sideListShown: true)), .oneRow)
    }

    func testHistoryNeverPresentsBySizeClassChange() {
        var panel = HistoryPanel()
        panel.toggle(regular: true)
        XCTAssertTrue(panel.showsList(regular: true))
        XCTAssertFalse(panel.showsSheet(regular: false))
        panel.sizeClassChanged()
        XCTAssertFalse(panel.showsSheet(regular: false))
        XCTAssertTrue(panel.showsList(regular: true))
        panel.toggle(regular: false)
        XCTAssertTrue(panel.showsSheet(regular: false))
        XCTAssertFalse(panel.showsList(regular: false))
        panel.sizeClassChanged()
        XCTAssertFalse(panel.showsSheet(regular: false))
        XCTAssertFalse(panel.showsSheet(regular: true))
        panel.close()
        XCTAssertFalse(panel.showsList(regular: true))
    }

    func testToolRowLayoutByWidth() {
        XCTAssertEqual(ToolRowLayout.oneRowWidth, 588)
        XCTAssertEqual(ToolRowLayout.oneRowWithPillWidth, 858)
        let table: [(CGFloat, ToolRowLayout)] = [(320, .twoRows), (375, .twoRows), (466, .twoRows), (587, .twoRows), (588, .oneRow), (669, .oneRow), (692, .oneRow), (857, .oneRow), (858, .oneRowWithPill), (1100, .oneRowWithPill), (1400, .oneRowWithPill)]
        for (width, expected) in table {
            XCTAssertEqual(ToolRowLayout.layout(forWidth: width), expected, "width \(width)")
        }
    }

    func testEveryToolbarItemHasOnePlacementInEachLayout() {
        for layout in [ToolRowLayout.oneRowWithPill, .oneRow, .twoRows] {
            let placed = EditorBarItem.placement(in: layout)
            let all = placed.leading + placed.toolRow + placed.bar + placed.menu
            XCTAssertEqual(all.count, EditorBarItem.allCases.count, "\(layout)")
            XCTAssertEqual(Set(all), Set(EditorBarItem.allCases), "\(layout)")
        }
        let oneRow = EditorBarItem.placement(in: .oneRow)
        XCTAssertEqual(oneRow.leading, [.settings, .history, .mode])
        XCTAssertEqual(oneRow.bar, [.mic, .undo, .redo, .new])
        XCTAssertEqual(oneRow.menu, [.replay, .crop, .window])
    }

    func testToolbarItemsAreIdenticalInEveryState() {
        let expected: [EditorBarItem] = [.settings, .history, .mode, .mic, .replay, .crop, .window, .undo, .redo, .new]
        var count = 0
        for mode in [EditorMode.draw, .note] {
            for phase in 0 ..< 3 {
                for selecting in [false, true] {
                    for canRedo in [false, true] {
                        for replayAvailable in [false, true] {
                            let state = EditorBarState(mode: mode, recording: phase == 1, transcribing: phase == 2, selecting: selecting, canRedo: canRedo, replayAvailable: replayAvailable)
                            XCTAssertEqual(EditorBarItem.items(for: state), expected, "\(state)")
                            count += 1
                        }
                    }
                }
            }
        }
        XCTAssertEqual(count, 48)
        XCTAssertFalse(EditorBarItem.mic.isEnabled(EditorBarState(mode: .draw)))
        XCTAssertTrue(EditorBarItem.mic.isEnabled(EditorBarState(mode: .note, recording: true)))
        XCTAssertFalse(EditorBarItem.redo.isEnabled(EditorBarState()))
        XCTAssertFalse(EditorBarItem.replay.isEnabled(EditorBarState()))
    }

    func testTranscriptRowShowsOnlyTimeAndPhrase() {
        let phrase = NotePhrase(start: 65, end: 70, text: "look here", marks: [1, 2, 3])
        XCTAssertEqual(TranscriptRow.visibleTexts(phrase), [ReplayTimeline.clock(65), "look here"])
    }

    func testStorageSizeAndDeleteAllAfterPendingEdit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try EditorModel(client: FakeClient(), defaults: XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), historyDirectory: directory)
        await model.newCapture()
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        let expected = try urls.reduce(Int64(0)) { try $0 + Int64($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        model.updateStorageSize()
        XCTAssertEqual(model.storageSize, expected)
        model.crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        await model.deleteAllHistory()
        await model.flushHistory()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        XCTAssertTrue(model.history.isEmpty)
        XCTAssertNil(model.image)
        XCTAssertEqual(model.storageSize, 0)
    }

    func testRetentionKeepsCurrentAndRecentCapture() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = CaptureHistory(directory: directory)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in }
        for (id, age) in [("current", 9), ("old", 8), ("recent", 6)] {
            _ = try storage.save(CaptureEntry(id: id, date: Date().addingTimeInterval(-Double(age) * 86400), image: image, drawing: PKDrawing(), crop: nil, windows: []))
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let model = EditorModel(client: nil, defaults: defaults, historyDirectory: directory)
        XCTAssertEqual(model.retention, .forever)
        await model.pruneHistoryAfterSave()
        XCTAssertEqual(model.history.count, 3)
        try await model.select(XCTUnwrap(model.history.first { $0.id == "current" }))
        model.retention = .week
        await model.pruneHistoryAfterSave()
        XCTAssertEqual(Set(model.history.map(\.id)), Set(["current", "recent"]))
        XCTAssertEqual(try Set(storage.load().map(\.id)), Set(["current", "recent"]))
        let restored = EditorModel(client: nil, defaults: defaults, historyDirectory: directory)
        XCTAssertEqual(restored.retention, .week)
        XCTAssertEqual(restored.history.map(\.id), ["recent"])
    }

    func testAppearanceDefaultsPersistsAndMapsToColorScheme() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let model = EditorModel(client: nil, defaults: defaults)
        XCTAssertEqual(model.appearance, .system)
        XCTAssertNil(model.appearance.colorScheme)
        model.appearance = .dark
        let restored = EditorModel(client: nil, defaults: defaults)
        XCTAssertEqual(restored.appearance, .dark)
        XCTAssertEqual(restored.appearance.colorScheme, .dark)
        XCTAssertEqual(Appearance.light.colorScheme, .light)
    }

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
        restored.setTool(.marker)
        restored.setInkColor(.blue)
        let again = EditorModel(client: nil, defaults: defaults)
        XCTAssertEqual(again.tool, .marker)
        XCTAssertEqual(again.inkColor, .blue)
        XCTAssertEqual(try EditorModel(client: nil, defaults: XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))).tool, .pen)
        let pen = try XCTUnwrap(EditorModel.pkTool(.pen, color: .green, width: 16, scale: 0.4) as? PKInkingTool)
        XCTAssertEqual(pen.inkType, .pen)
        XCTAssertEqual(pen.color, InkColor.green.color)
        XCTAssertEqual(pen.width, 6.4, accuracy: 0.001)
        let marker = try XCTUnwrap(EditorModel.pkTool(.marker, color: .red, width: 4, scale: 0.4) as? PKInkingTool)
        XCTAssertEqual(marker.inkType, .marker)
        XCTAssertEqual(marker.width, max(1.6, PKInkingTool.InkType.marker.validWidthRange.lowerBound), accuracy: 0.001)
        let eraser = try XCTUnwrap(EditorModel.pkTool(.eraser, color: .red, width: 4, scale: 1) as? PKEraserTool)
        XCTAssertEqual(eraser.eraserType, .vector)
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

    func testInboxImportsAndKeepsPreviousSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = FakeClient()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let shared = UIGraphicsImageRenderer(size: CGSize(width: 17, height: 11), format: format).image { _ in }
        var inbox: UIImage?
        let model = try EditorModel(client: client, defaults: XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), historyDirectory: directory, takeInboxImage: {
            defer { inbox = nil }
            return inbox
        })
        await model.newCapture()
        let previous = try XCTUnwrap(model.history.first?.id)
        client.captures = 0
        inbox = shared
        await model.activate()
        XCTAssertEqual(client.captures, 0)
        XCTAssertEqual(model.image?.size, shared.size)
        XCTAssertEqual(client.sessions.count, 1)
        XCTAssertNotEqual(client.sessions.first, previous)
        XCTAssertTrue(model.history.contains { $0.id == previous })
        await model.activate()
        XCTAssertEqual(client.captures, 0)
        XCTAssertEqual(model.image?.size, shared.size)
        let imported = try XCTUnwrap(model.history.first { $0.id == client.sessions.first })
        await model.newCapture()
        await model.select(imported)
        let captures = client.captures
        await model.activate()
        XCTAssertEqual(client.captures, captures)
        XCTAssertEqual(model.image?.size, shared.size)
    }

    func testInboxDownscalesAndRotatesPhoto() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 6000, height: 4000), format: format).image { _ in }
        let url = directory.appendingPathComponent("photo.jpg")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil))
        try CGImageDestinationAddImage(destination, XCTUnwrap(image.cgImage), [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let result = try XCTUnwrap(SharedInbox(directory: directory).takeNewest())
        XCTAssertEqual(result.size, CGSize(width: 2731, height: 4096))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
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
        let firstSend = expectation(description: "first send")
        let secondSend = expectation(description: "second send")
        client.onPaste = { client.sessions.count == 1 ? firstSend.fulfill() : secondSend.fulfill() }
        await model.activate()
        XCTAssertTrue(client.sessions.isEmpty)
        model.crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        await Task.yield()
        model.crop = CGRect(x: 0, y: 0, width: 2, height: 1)
        await Task.yield()
        model.crop = CGRect(x: 0, y: 0, width: 2, height: 2)
        await Task.yield()
        clock.advance()
        await fulfillment(of: [firstSend], timeout: 5)
        XCTAssertEqual(client.sessions.count, 1)
        XCTAssertEqual(try UIImage(data: XCTUnwrap(client.images.first))?.size, CGSize(width: 2, height: 2))
        await model.newCapture()
        await clock.settle()
        XCTAssertEqual(client.sessions.count, 1)
        model.crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        await Task.yield()
        clock.advance()
        await fulfillment(of: [secondSend], timeout: 5)
        XCTAssertEqual(client.sessions.count, 2)
        guard client.sessions.count == 2 else { return }
        XCTAssertNotEqual(client.sessions[0], client.sessions[1])
    }

    func testEditDuringSendIsSentOnceAfterCompletion() async throws {
        let client = FakeClient()
        client.holdPaste = true
        let clock = TestDelay()
        let model = try EditorModel(client: client, defaults: XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), delay: { try await clock.wait() })
        let firstSend = expectation(description: "first send")
        let secondSend = expectation(description: "second send")
        client.onPaste = { client.sessions.count == 1 ? firstSend.fulfill() : secondSend.fulfill() }
        await model.activate()
        model.crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        await Task.yield()
        clock.advance()
        await fulfillment(of: [firstSend], timeout: 5)
        XCTAssertEqual(client.sessions.count, 1)
        model.crop = CGRect(x: 0, y: 0, width: 2, height: 2)
        await Task.yield()
        clock.advance()
        await clock.settle()
        XCTAssertEqual(client.sessions.count, 1)
        client.finishPaste()
        await fulfillment(of: [secondSend], timeout: 5)
        XCTAssertEqual(client.sessions.count, 2)
        XCTAssertEqual(client.sessions.first, client.sessions.last)
        XCTAssertEqual(try UIImage(data: XCTUnwrap(client.images.last))?.size, CGSize(width: 2, height: 2))
        client.finishPaste()
    }

    func testDrawingDefersSendAndRendersOffMainThread() async throws {
        let client = FakeClient()
        let clock = TestDelay()
        let sent = expectation(description: "sent")
        client.onPaste = { sent.fulfill() }
        let model = try EditorModel(client: client, defaults: XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), delay: { try await clock.wait() }, render: { image, drawing, crop in
            XCTAssertFalse(Thread.isMainThread)
            return try ImageRenderer.png(image: image, drawing: drawing, crop: crop)
        })
        await model.activate()
        model.setUsingTool(true)
        model.crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        await Task.yield()
        clock.advance()
        await clock.settle()
        XCTAssertTrue(client.sessions.isEmpty)
        model.setUsingTool(false)
        await Task.yield()
        clock.advance()
        await fulfillment(of: [sent], timeout: 5)
        XCTAssertEqual(client.sessions.count, 1)
    }

    func testHistorySavesLatestEditOffMainThread() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try EditorModel(client: FakeClient(), defaults: XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), saveCapture: { storage, entry in
            XCTAssertFalse(Thread.isMainThread)
            return try storage.save(entry)
        }, historyDirectory: directory)
        await model.newCapture()
        model.crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        model.crop = CGRect(x: 0, y: 0, width: 2, height: 2)
        await model.flushHistory()
        let storage = CaptureHistory(directory: directory)
        let entry = try XCTUnwrap(storage.load().first)
        XCTAssertEqual(try storage.loadCapture(entry).crop, CGRect(x: 0, y: 0, width: 2, height: 2))
    }

    func testFailedHistorySaveKeepsCaptureAndRetries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writes = HistoryWrites()
        let model = try EditorModel(client: FakeClient(), defaults: XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), saveCapture: { storage, entry in
            try writes.save(storage, entry)
        }, historyDirectory: directory)
        await model.newCapture()
        let original = try XCTUnwrap(model.image)
        let id = try XCTUnwrap(model.history.first?.id)
        writes.setFailure(true)
        model.crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        await model.newCapture()
        XCTAssertTrue(model.image === original)
        XCTAssertEqual(model.crop, CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertNotNil(model.error)
        writes.setFailure(false)
        await model.newCapture()
        XCTAssertFalse(model.image === original)
        let storage = CaptureHistory(directory: directory)
        let saved = try XCTUnwrap(storage.load().first { $0.id == id })
        XCTAssertEqual(try storage.loadCapture(saved).crop, CGRect(x: 0, y: 0, width: 1, height: 1))
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
        XCTAssertEqual(saved.crop, CGRect(x: 0, y: 0, width: 1, height: 1))
        await restored.select(saved)
        XCTAssertEqual(restored.drawing.strokes.count, expectedDrawing.strokes.count)
        XCTAssertEqual(restored.drawing.strokes.first?.path.first?.location, expectedDrawing.strokes.first?.path.first?.location)
        XCTAssertEqual(client.sessions, [first.id])
        let expected = try ImageRenderer.png(image: XCTUnwrap(restored.image), drawing: restored.drawing, crop: restored.crop)
        XCTAssertEqual(client.images, [expected])
        await restored.deleteHistory(saved)
        XCTAssertNil(restored.image)
        XCTAssertFalse(restored.history.contains { $0.id == saved.id })
        let reloaded = EditorModel(client: nil, defaults: defaults, historyDirectory: directory)
        XCTAssertFalse(reloaded.history.contains { $0.id == saved.id })
    }

    func testHistoryThumbnailAndLazyOriginalLoading() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = CaptureHistory(directory: directory)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 400), format: format).image { _ in }
        let capture = CaptureEntry(id: "sample", date: Date(), image: image, drawing: PKDrawing(), crop: CGRect(x: 100, y: 0, width: 600, height: 400), windows: [])
        _ = try storage.save(capture)
        let thumbnail = try XCTUnwrap(UIImage(contentsOfFile: directory.appendingPathComponent("sample.thumbnail").path)?.cgImage)
        XCTAssertEqual(thumbnail.width, 240)
        XCTAssertEqual(thumbnail.height, 160)
        let original = directory.appendingPathComponent("sample.png")
        let moved = directory.appendingPathComponent("original")
        try FileManager.default.moveItem(at: original, to: moved)
        let model = try EditorModel(client: nil, defaults: XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), historyDirectory: directory)
        let entry = try XCTUnwrap(model.history.first)
        XCTAssertNotNil(entry.thumbnail)
        await model.select(entry)
        XCTAssertNil(model.image)
        XCTAssertNotNil(model.error)
        try FileManager.default.moveItem(at: moved, to: original)
        await model.select(entry)
        XCTAssertEqual(model.image?.cgImage?.width, 800)
    }

    func testDeleteCurrentAndOtherHistoryAfterDebounce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestDelay()
        let model = try EditorModel(client: FakeClient(), defaults: XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), delay: { try await clock.wait() }, historyDirectory: directory)
        await model.newCapture()
        let other = try XCTUnwrap(model.history.first)
        await model.newCapture()
        let current = try XCTUnwrap(model.history.first)
        model.crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        await Task.yield()
        await model.deleteHistory(other)
        await model.deleteHistory(current)
        clock.advance()
        await clock.settle()
        XCTAssertNil(model.image)
        XCTAssertTrue(model.history.isEmpty)
        for entry in [other, current] {
            for suffix in ["json", "png", "drawing", "thumbnail"] {
                XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(entry.id + "." + suffix).path))
            }
        }
    }

    func testHistoryKeepsMoreThanFiftyAndCropUndo() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = FakeClient()
        let model = try EditorModel(client: client, defaults: XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), historyDirectory: directory)
        for _ in 0 ..< 51 {
            await model.newCapture()
        }
        XCTAssertEqual(model.history.count, 51)
        let restored = try EditorModel(client: nil, defaults: XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), historyDirectory: directory)
        XCTAssertEqual(restored.history.count, 51)
        let image = try XCTUnwrap(model.image)
        model.applyCrop(CGRect(x: 0, y: 0, width: 1, height: 1))
        let cropped = try XCTUnwrap(UIImage(data: ImageRenderer.png(image: image, drawing: model.drawing, crop: model.crop))?.cgImage)
        XCTAssertEqual(cropped.width, 1)
        model.undo()
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
        model.undo()
        XCTAssertNil(model.crop)
        model.resetWindowSelection()
        XCTAssertEqual(model.selectWindow(at: point, confirm: true), front)
        await model.flushHistory()
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

private final class HistoryWrites {
    private let lock = NSLock()
    private var fail = false

    func setFailure(_ value: Bool) {
        lock.lock()
        fail = value
        lock.unlock()
    }

    func save(_ storage: CaptureHistory, _ entry: CaptureEntry) throws -> HistoryEntry {
        lock.lock()
        let failed = fail
        lock.unlock()
        if failed {
            throw CocoaError(.fileWriteUnknown)
        }
        return try storage.save(entry)
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
    var onPaste: (() -> Void)?
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

    func note(annotated _: Data, screenshot _: Data, note _: Note, session _: String) async throws {}

    func paste(_ data: Data, session: String) async throws {
        sessions.append(session)
        images.append(data)
        onPaste?()
        if holdPaste {
            await withCheckedContinuation { pendingPaste = $0 }
        }
    }

    func finishPaste() {
        pendingPaste?.resume(); pendingPaste = nil
    }

    func testUndoRedoOrdersStrokesAndCrop() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = try EditorModel(client: FakeClient(), defaults: XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)), historyDirectory: directory)
        await model.newCapture()
        XCTAssertFalse(model.canUndo)
        XCTAssertFalse(model.canRedo)
        func stroke(_ x: CGFloat) -> PKStroke {
            let point = PKStrokePoint(location: CGPoint(x: x, y: x), timeOffset: 0, size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: 0)
            return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: [point, point], creationDate: Date()))
        }
        let cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        model.drawing = PKDrawing(strokes: [stroke(1)])
        model.applyCrop(cropRect)
        model.drawing = PKDrawing(strokes: [stroke(1), stroke(2)])
        model.undo()
        XCTAssertEqual(model.drawing.strokes.count, 1)
        XCTAssertEqual(model.crop, cropRect)
        XCTAssertTrue(model.canRedo)
        model.undo()
        XCTAssertNil(model.crop)
        XCTAssertEqual(model.drawing.strokes.count, 1)
        model.undo()
        XCTAssertEqual(model.drawing.strokes.count, 0)
        XCTAssertFalse(model.canUndo)
        model.redo()
        XCTAssertEqual(model.drawing.strokes.count, 1)
        XCTAssertNil(model.crop)
        model.redo()
        XCTAssertEqual(model.crop, cropRect)
        XCTAssertTrue(model.canRedo)
        model.drawing = PKDrawing(strokes: [stroke(1), stroke(3)])
        XCTAssertFalse(model.canRedo)
        model.undo()
        XCTAssertTrue(model.canUndo)
        await model.newCapture()
        XCTAssertFalse(model.canUndo)
        XCTAssertFalse(model.canRedo)
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
