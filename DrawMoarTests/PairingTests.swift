import CompanionKit
@testable import DrawMoar
import UIKit
import XCTest

@MainActor final class PairingTests: XCTestCase {
    func testInviteFromURL() throws {
        let invite = PairingInvite(macName: "My Mac", secret: Data(repeating: 7, count: 32))
        XCTAssertEqual(try PairingFlow.invite(from: invite.url), invite)
        var components = try XCTUnwrap(URLComponents(url: invite.url, resolvingAgainstBaseURL: false))
        components.scheme = "https"
        XCTAssertThrowsError(try PairingFlow.invite(from: XCTUnwrap(components.url)))
        components.scheme = "drawmoar"
        components.queryItems?.removeAll { $0.name == "key" }
        XCTAssertThrowsError(try PairingFlow.invite(from: XCTUnwrap(components.url)))
    }

    func testPairAndForgetKeepDeviceId() async throws {
        let invite = PairingInvite(macName: "My Mac", secret: Data(repeating: 7, count: 32))
        let id = try PairingStore.deviceId()
        var requests: [(PairingInvite, String)] = []
        let flow = PairingFlow(connect: { received, deviceId in
            requests.append((received, deviceId))
            return Pairing(deviceId: deviceId, key: Data([1]), macName: received.macName)
        })
        let first = await flow.pair(url: invite.url)
        XCTAssertEqual(first?.deviceId, id)
        try PairingStore.delete()
        let second = await flow.pair(url: invite.url)
        XCTAssertEqual(second?.deviceId, id)
        XCTAssertEqual(requests.map(\.0), [invite, invite])
        XCTAssertEqual(requests.map(\.1), [id, id])
        try PairingStore.delete()
    }

    func testPairClosesSettingsAndCapturesOnlyOnSuccess() async {
        let invite = PairingInvite(macName: "My Mac", secret: Data(repeating: 7, count: 32))
        let client = PairingCaptureClient()
        let model = EditorModel(client: client)
        var fails = false
        let flow = PairingFlow(deviceId: { "device" }, connect: { invite, id in
            if fails {
                throw MacError.unavailable
            }
            return Pairing(deviceId: id, key: Data([1]), macName: invite.macName)
        }, save: { _ in })
        flow.showSettings = true
        await flow.pair(url: invite.url) { _ in await model.newCapture() }
        XCTAssertFalse(flow.showSettings)
        XCTAssertEqual(client.captures, 1)
        fails = true
        flow.showSettings = true
        await flow.pair(url: invite.url) { _ in await model.newCapture() }
        XCTAssertTrue(flow.showSettings)
        XCTAssertNotNil(flow.error)
        XCTAssertEqual(client.captures, 1)
    }
}

@MainActor private final class PairingCaptureClient: MacCapturing {
    var captures = 0

    func capture(displayId _: UInt32?) async throws -> (png: Data, windows: [WindowFrame]) {
        captures += 1
        return (UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in }.pngData()!, [])
    }

    func displays() async throws -> [DisplayInfo] {
        []
    }

    func paste(_: Data, session _: String) async throws {}
}
