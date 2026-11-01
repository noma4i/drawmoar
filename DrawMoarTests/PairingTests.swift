import CompanionKit
@testable import DrawMoar
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
}
