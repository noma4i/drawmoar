import CompanionKit
import CryptoKit
import Foundation
import Network
import Observation

struct Mac: Identifiable, Hashable {
    let name: String
    let endpoint: NWEndpoint
    var id: NWEndpoint {
        endpoint
    }
}

@MainActor @Observable final class MacBrowser {
    var macs: [Mac] = []
    var error: String?
    private var browser: NWBrowser?
    private var lastRoutes: [String: NWEndpoint] = [:]
    private var connectedRoutes: [String: NWEndpoint] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, start: Bool = true) {
        self.defaults = defaults
        if start {
            restart()
        }
    }

    func restart() {
        browser?.cancel()
        macs = []
        let browser = NWBrowser(for: .bonjour(type: bonjourServiceType, domain: nil), using: .tcp)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            let macs = results.compactMap { result -> Mac? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return Mac(name: name, endpoint: result.endpoint)
            }.sorted { $0.name < $1.name }
            Task { @MainActor in
                guard let browser, self?.browser === browser else { return }
                self?.macs = macs
            }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            if case let .failed(error) = state {
                Task { @MainActor in
                    guard let browser, self?.browser === browser else { return }
                    self?.error = error.localizedDescription
                    self?.restart()
                }
            }
        }
        browser.start(queue: .main)
    }

    isolated deinit { browser?.cancel() }

    func remoteAddress(for name: String) -> String {
        defaults.string(forKey: "remoteAddress.\(name)") ?? ""
    }

    func setRemoteAddress(_ address: String, for name: String) {
        defaults.set(address, forKey: "remoteAddress.\(name)")
    }

    func connectedRoute(for name: String) -> String? {
        guard let endpoint = connectedRoutes[name] else { return nil }
        guard case let .hostPort(host, _) = endpoint else { return "Local network" }
        let value = "\(host)"
        let parts = value.split(separator: ".").compactMap { UInt8($0) }
        if value.lowercased().hasSuffix(".ts.net") || (parts.count == 4 && parts[0] == 100 && (64 ... 127).contains(parts[1])) {
            return "Tailscale"
        }
        return value
    }

    func recordResponse(from endpoint: NWEndpoint, for name: String) {
        connectedRoutes[name] = endpoint
    }

    func connect(name: String, hosts: [String], port: UInt16?, identity: String, key: SymmetricKey) async throws -> (CompanionConnection, NWEndpoint) {
        try await connect(name: name, hosts: hosts, port: port) { endpoint in
            let connection = CompanionConnection(NWConnection(to: endpoint, using: CompanionTLS.clientParameters(identity: identity, key: key)))
            do {
                try await connection.ready(timeout: .seconds(4))
                return (connection, endpoint)
            } catch {
                connection.connection.cancel()
                throw error
            }
        }
    }

    func connect<T>(name: String, hosts: [String], port: UInt16?, using connector: (NWEndpoint) async throws -> T) async throws -> T {
        let service = NWEndpoint.service(name: name, type: bonjourServiceType, domain: "local.", interface: nil)
        let remote = remoteAddress(for: name).trimmingCharacters(in: .whitespacesAndNewlines)
        let port = NWEndpoint.Port(rawValue: port ?? CompanionTLS.port)!
        var routes = [service]
        for host in hosts + [remote] where !host.isEmpty {
            let route = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)
            if !routes.contains(route) {
                routes.append(route)
            }
        }
        if let last = lastRoutes[name], let index = routes.firstIndex(of: last) {
            routes.remove(at: index)
            routes.insert(last, at: 0)
        }
        for route in routes {
            do {
                let result = try await connector(route)
                lastRoutes[name] = route
                return result
            } catch is CancellationError {
                throw CancellationError()
            } catch {}
        }
        throw MacError.unavailable
    }
}
