import CompanionKit
import CryptoKit
import Foundation
import Network
import UIKit

protocol MacCapturing {
    func capture(displayId: UInt32?) async throws -> (png: Data, windows: [WindowFrame])
    func displays() async throws -> [DisplayInfo]
    func paste(_ data: Data, session: String) async throws
    func note(annotated: Data, screenshot: Data, note: Note, session: String) async throws
}

enum MacError: LocalizedError {
    case unavailable([String]), disconnected, unexpected, expiredInvite, invalidInvite, remote(String)
    var errorDescription: String? {
        switch self {
        case let .unavailable(failures): "Mac not reachable. " + failures.joined(separator: "; ")
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

    static func pair(invite: PairingInvite, deviceId: String, browser: MacBrowser) async throws -> Pairing {
        let (connection, _) = try await browser.connect(name: invite.macName, hosts: invite.hosts, port: invite.port, identity: "pair", key: CompanionTLS.pairingKey(secret: invite.secret))
        defer { connection.connection.cancel() }
        var iterator = connection.messages.makeAsyncIterator()
        do {
            try await connection.send(.pairRequest(deviceId: deviceId, deviceName: UIDevice.current.name))
            guard let response = try await iterator.next() else { throw MacError.disconnected }
            switch response {
            case let .pairGranted(key): return Pairing(deviceId: deviceId, key: key, invite: invite)
            case let .error(message): throw MacError.remote(message)
            default: throw MacError.unexpected
            }
        } catch let error as MacError { throw error }
        catch { throw MacError.expiredInvite }
    }

    func capture(displayId: UInt32?) async throws -> (png: Data, windows: [WindowFrame]) {
        guard case let .screenshot(png, windows) = try await request(.capture(displayId: displayId)) else { throw MacError.unexpected }
        return (png, windows)
    }

    func displays() async throws -> [DisplayInfo] {
        guard case let .displays(displays) = try await request(.listDisplays) else { throw MacError.unexpected }
        return displays
    }

    func paste(_ data: Data, session: String) async throws {
        guard case .ok = try await request(.paste(png: data, session: session)) else { throw MacError.unexpected }
    }

    func note(annotated: Data, screenshot: Data, note: Note, session: String) async throws {
        guard case .ok = try await request(.note(annotated: annotated, screenshot: screenshot, note: note, session: session)) else { throw MacError.unexpected }
    }

    private func request(_ message: Message) async throws -> Message {
        var retried = false
        while true {
            let (connection, endpoint) = try await browser.connect(name: pairing.macName, hosts: pairing.hosts ?? [], port: pairing.port, identity: pairing.deviceId, key: SymmetricKey(data: pairing.key))
            let watch = ConnectionWatch(connection.connection)
            let stopObserving = browser.onPathChange { watch.drop() }
            defer { stopObserving() }
            do {
                let response = try await Self.request(message, connection: connection, pairing: pairing)
                browser.recordResponse(from: endpoint, for: pairing.macName)
                return response
            } catch {
                guard !retried, watch.dropped || isDisconnect(error) else { throw error }
                retried = true
                browser.forgetRoute(for: pairing.macName)
            }
        }
    }

    private func isDisconnect(_ error: Error) -> Bool {
        if case MacError.disconnected = error {
            return true
        }
        return false
    }

    private nonisolated static func request(_ message: Message, connection: CompanionConnection, pairing: Pairing) async throws -> Message {
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

@MainActor private final class ConnectionWatch {
    private let connection: NWConnection
    private(set) var dropped = false

    init(_ connection: NWConnection) {
        self.connection = connection
        connection.viabilityUpdateHandler = { [weak self] viable in
            if !viable {
                Task { @MainActor in self?.drop() }
            }
        }
        connection.betterPathUpdateHandler = { [weak self] better in
            if better {
                Task { @MainActor in self?.drop() }
            }
        }
    }

    func drop() {
        dropped = true
        connection.cancel()
    }
}
