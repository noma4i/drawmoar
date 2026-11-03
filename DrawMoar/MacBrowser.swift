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
    private(set) var pathGeneration = 0
    private var pathMonitor: NWPathMonitor?
    private var pathSignature: String?
    private var pathObservers: [UUID: @MainActor () -> Void] = [:]
    private let defaults: UserDefaults
    private let sleep: @Sendable (Duration) async throws -> Void

    static let routeStagger = Duration.milliseconds(100)
    static let lanGrace = Duration.milliseconds(250)
    static let raceTimeout = Duration.seconds(6)

    init(defaults: UserDefaults = .standard, start: Bool = true, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.defaults = defaults
        self.sleep = sleep
        if start {
            restart()
            watchPath()
        }
    }

    private func watchPath() {
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let signature = "\(path.status) " + path.availableInterfaces.map(\.name).sorted().joined(separator: ",")
            Task { @MainActor in self?.observe(signature) }
        }
        monitor.start(queue: .main)
    }

    private func observe(_ signature: String) {
        let previous = pathSignature
        pathSignature = signature
        if let previous, previous != signature {
            pathChanged()
        }
    }

    func pathChanged() {
        pathGeneration += 1
        lastRoutes = [:]
        connectedRoutes = [:]
        for observer in pathObservers.values {
            observer()
        }
    }

    func onPathChange(_ observer: @escaping @MainActor () -> Void) -> () -> Void {
        let id = UUID()
        pathObservers[id] = observer
        return { [weak self] in self?.pathObservers[id] = nil }
    }

    func forgetRoute(for name: String) {
        lastRoutes[name] = nil
        connectedRoutes[name] = nil
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

    isolated deinit {
        browser?.cancel()
        pathMonitor?.cancel()
    }

    func remoteAddress(for name: String) -> String {
        defaults.string(forKey: "remoteAddress.\(name)") ?? ""
    }

    func setRemoteAddress(_ address: String, for name: String) {
        defaults.set(address, forKey: "remoteAddress.\(name)")
    }

    func connectedRoute(for name: String) -> String? {
        guard let endpoint = connectedRoutes[name] else { return nil }
        guard case let .hostPort(host, _) = endpoint else { return "Bonjour" }
        let value = "\(host)"
        let remote = remoteAddress(for: name).trimmingCharacters(in: .whitespacesAndNewlines)
        switch Self.routeKind(endpoint) {
        case .tailscale: return "Tailscale"
        case _ where value == remote: return "Remote address"
        case .lan: return "Bonjour"
        case .other: return value
        }
    }

    enum RouteKind { case lan, tailscale, other }

    nonisolated static func routeKind(_ endpoint: NWEndpoint) -> RouteKind {
        guard case let .hostPort(host, _) = endpoint else { return .lan }
        let value = "\(host)".lowercased()
        let parts = value.split(separator: ".").compactMap { UInt8($0) }
        if value.hasSuffix(".ts.net") || (parts.count == 4 && parts[0] == 100 && (64 ... 127).contains(parts[1])) {
            return .tailscale
        }
        if value.hasSuffix(".local") {
            return .lan
        }
        if parts.count == 4, parts[0] == 10 || (parts[0] == 172 && (16 ... 31).contains(parts[1])) || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 169 && parts[1] == 254) {
            return .lan
        }
        return .other
    }

    func recordResponse(from endpoint: NWEndpoint, for name: String) {
        connectedRoutes[name] = endpoint
    }

    func connect(name: String, hosts: [String], port: UInt16?, identity: String, key: SymmetricKey) async throws -> (CompanionConnection, NWEndpoint) {
        try await connect(name: name, hosts: hosts, port: port, using: { endpoint in
            let connection = CompanionConnection(NWConnection(to: endpoint, using: CompanionTLS.clientParameters(identity: identity, key: key)))
            do {
                try await connection.ready(timeout: Self.raceTimeout)
                return (connection, endpoint)
            } catch {
                connection.connection.cancel()
                throw error
            }
        }, discard: { $0.0.connection.cancel() })
    }

    func connect<T>(name: String, hosts: [String], port: UInt16?, using connector: @escaping @MainActor (NWEndpoint) async throws -> T, discard: @escaping @MainActor (T) -> Void = { _ in }) async throws -> T {
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
        let race = RouteRace<T>(routes: routes, sleep: sleep, connector: connector, discard: discard)
        let (result, route) = try await race.run()
        lastRoutes[name] = route
        return result
    }
}

@MainActor private final class RouteRace<T> {
    private let routes: [NWEndpoint]
    private let sleep: @Sendable (Duration) async throws -> Void
    private let connector: @MainActor (NWEndpoint) async throws -> T
    private let discard: @MainActor (T) -> Void
    private var continuation: CheckedContinuation<(T, NWEndpoint), Error>?
    private var tasks: [Task<Void, Never>] = []
    private var graceTask: Task<Void, Never>?
    private var failures: [String] = []
    private var pending: Int
    private var pendingLAN: Int
    private var held: (T, NWEndpoint)?
    private var done = false

    init(routes: [NWEndpoint], sleep: @escaping @Sendable (Duration) async throws -> Void, connector: @escaping @MainActor (NWEndpoint) async throws -> T, discard: @escaping @MainActor (T) -> Void) {
        self.routes = routes
        self.sleep = sleep
        self.connector = connector
        self.discard = discard
        pending = routes.count
        pendingLAN = routes.count { MacBrowser.routeKind($0) == .lan }
    }

    func run() async throws -> (T, NWEndpoint) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                start()
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func start() {
        guard !Task.isCancelled else { return finish(.failure(CancellationError())) }
        let sleep = sleep
        for (index, route) in routes.enumerated() {
            tasks.append(Task { @MainActor in
                if index > 0 {
                    do { try await sleep(MacBrowser.routeStagger * index) } catch { return }
                }
                do {
                    try succeed(await connector(route), route)
                } catch {
                    fail(route, error)
                }
            })
        }
        tasks.append(Task { @MainActor in
            do { try await sleep(MacBrowser.raceTimeout) } catch { return }
            if let held {
                finish(.success(held))
            } else {
                finish(.failure(MacError.unavailable(failures + ["timed out"])))
            }
        })
    }

    private func settle(_ route: NWEndpoint) {
        pending -= 1
        if MacBrowser.routeKind(route) == .lan {
            pendingLAN -= 1
        }
    }

    private func succeed(_ value: T, _ route: NWEndpoint) {
        settle(route)
        guard !done, held == nil || MacBrowser.routeKind(route) == .lan else { return discard(value) }
        if MacBrowser.routeKind(route) == .lan || pendingLAN == 0 {
            return finish(.success((value, route)))
        }
        held = (value, route)
        let sleep = sleep
        graceTask = Task { @MainActor in
            do { try await sleep(MacBrowser.lanGrace) } catch { return }
            if let held {
                finish(.success(held))
            }
        }
    }

    private func fail(_ route: NWEndpoint, _ error: Error) {
        settle(route)
        guard !done else { return }
        let label: String
        if case let .hostPort(host, _) = route {
            label = "\(host)"
        } else {
            label = "Local network"
        }
        let description: String
        if case CompanionConnectionError.timedOut = error {
            description = "timed out"
        } else {
            description = error.localizedDescription
        }
        failures.append("\(label): \(description.prefix(80))")
        if let held, pendingLAN == 0 {
            finish(.success(held))
        } else if pending == 0, held == nil {
            finish(.failure(MacError.unavailable(failures)))
        }
    }

    private func finish(_ result: Result<(T, NWEndpoint), Error>) {
        guard !done, let continuation else { return }
        done = true
        for task in tasks + [graceTask].compactMap({ $0 }) {
            task.cancel()
        }
        if let held {
            if case let .success(winner) = result, winner.1 == held.1 {} else {
                discard(held.0)
            }
        }
        held = nil
        self.continuation = nil
        continuation.resume(with: result)
    }
}
