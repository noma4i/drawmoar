import CompanionKit
import CryptoKit
import Foundation
import Network
import UIKit

protocol MacCapturing {
    func capture(displayId: UInt32?) async throws -> Data
    func displays() async throws -> [DisplayInfo]
    func paste(_ data: Data, session: String) async throws
}

enum MacError: LocalizedError {
    case unavailable, disconnected, unexpected, expiredInvite, invalidInvite, remote(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: "Mac not found on the local network"
        case .disconnected: "Connection closed"
        case .unexpected: "Unexpected response from Mac"
        case .expiredInvite: "Pairing link expired. Open Pair device on your Mac and try again."
        case .invalidInvite: "Invalid pairing link"
        case let .remote(message): message
        }
    }
}

@MainActor final class MacClient: MacCapturing {
    let pairing: Pairing
    let browser: MacBrowser

    init(pairing: Pairing, browser: MacBrowser) {
        self.pairing = pairing
        self.browser = browser
    }

    static func pair(mac: Mac, invite: PairingInvite, deviceId: String) async throws -> Pairing {
        let connection = CompanionConnection(NWConnection(to: mac.endpoint, using: CompanionTLS.clientParameters(identity: "pair", key: CompanionTLS.pairingKey(secret: invite.secret))))
        defer { connection.connection.cancel() }
        var iterator = connection.messages.makeAsyncIterator()
        do {
            try await connection.send(.pairRequest(deviceId: deviceId, deviceName: UIDevice.current.name))
            guard let response = try await iterator.next() else { throw MacError.disconnected }
            switch response {
            case let .pairGranted(key): return Pairing(deviceId: deviceId, key: key, macName: mac.name)
            case let .error(message): throw MacError.remote(message)
            default: throw MacError.unexpected
            }
        } catch let error as MacError { throw error }
        catch { throw MacError.expiredInvite }
    }

    func capture(displayId: UInt32?) async throws -> Data {
        guard case let .image(data) = try await request(.capture(displayId: displayId)) else { throw MacError.unexpected }
        return data
    }

    func displays() async throws -> [DisplayInfo] {
        guard case let .displays(displays) = try await request(.listDisplays) else { throw MacError.unexpected }
        return displays
    }

    func paste(_ data: Data, session: String) async throws {
        guard case .ok = try await request(.paste(png: data, session: session)) else { throw MacError.unexpected }
    }

    private func request(_ message: Message) async throws -> Message {
        guard let mac = browser.macs.first(where: { $0.name == pairing.macName }) else { throw MacError.unavailable }
        let connection = CompanionConnection(NWConnection(to: mac.endpoint, using: CompanionTLS.clientParameters(identity: pairing.deviceId, key: SymmetricKey(data: pairing.key))))
        defer { connection.connection.cancel() }
        var iterator = connection.messages.makeAsyncIterator()
        try await connection.send(.hello(deviceId: pairing.deviceId))
        try await connection.send(message)
        guard let response = try await iterator.next() else { throw MacError.disconnected }
        if case let .error(message) = response {
            throw MacError.remote(message)
        }
        return response
    }
}
