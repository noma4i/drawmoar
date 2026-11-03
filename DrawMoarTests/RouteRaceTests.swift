import CompanionKit
@testable import DrawMoar
import Network
import XCTest

final class VirtualClock: @unchecked Sendable {
    private struct Sleeper {
        let id: UUID
        let deadline: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var sleepers: [Sleeper] = []
    private var current = Duration.zero

    var now: Duration {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                register(id, duration, continuation)
            }
        } onCancel: {
            cancel(id)
        }
    }

    private func register(_ id: UUID, _ duration: Duration, _ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        defer { lock.unlock() }
        if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
        } else {
            sleepers.append(Sleeper(id: id, deadline: current + duration, continuation: continuation))
        }
    }

    private func cancel(_ id: UUID) {
        lock.lock()
        let sleeper = sleepers.first { $0.id == id }
        sleepers.removeAll { $0.id == id }
        lock.unlock()
        sleeper?.continuation.resume(throwing: CancellationError())
    }

    @MainActor func settle() async {
        for _ in 0 ..< 40 {
            await Task.yield()
        }
    }

    @MainActor func advanceToNext() async -> Bool {
        lock.lock()
        guard let next = sleepers.min(by: { $0.deadline < $1.deadline }) else {
            lock.unlock()
            return false
        }
        sleepers.removeAll { $0.id == next.id }
        current = max(current, next.deadline)
        lock.unlock()
        next.continuation.resume()
        await settle()
        return true
    }
}

@MainActor final class RouteHarness {
    let clock = VirtualClock()
    let browser: MacBrowser
    let service = NWEndpoint.service(name: "Mac", type: bonjourServiceType, domain: "local.", interface: nil)
    let tailscale = NWEndpoint.hostPort(host: "100.90.189.102", port: 47823)
    var script: [NWEndpoint: (delay: Duration, fails: Bool)] = [:]
    var started: [NWEndpoint] = []

    init(remote: String? = nil) throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let clock = clock
        browser = MacBrowser(defaults: defaults, start: false, sleep: { try await clock.sleep($0) })
        if let remote {
            browser.setRemoteAddress(remote, for: "Mac")
        }
    }

    func race(hosts: [String] = ["100.90.189.102"]) async -> (result: Result<NWEndpoint, Error>, elapsed: Duration) {
        let begin = clock.now
        var outcome: (Result<NWEndpoint, Error>, Duration)?
        let browser = browser
        let task = Task { @MainActor in
            do {
                let route = try await browser.connect(name: "Mac", hosts: hosts, port: 47823) { [self] endpoint in
                    started.append(endpoint)
                    let step = script[endpoint] ?? (.seconds(60), true)
                    try await clock.sleep(step.delay)
                    if step.fails {
                        throw MacError.disconnected
                    }
                    return endpoint
                }
                outcome = (.success(route), clock.now - begin)
            } catch {
                outcome = (.failure(error), clock.now - begin)
            }
        }
        await clock.settle()
        while outcome == nil, await clock.advanceToNext() {}
        task.cancel()
        return (outcome!.0, outcome!.1)
    }
}

@MainActor final class RouteRaceTests: XCTestCase {
    func testTailscaleWinsWhenBonjourFails() async throws {
        let harness = try RouteHarness()
        harness.script = [harness.service: (.milliseconds(10), true), harness.tailscale: (.milliseconds(80), false)]
        let (result, elapsed) = await harness.race()
        XCTAssertEqual(try result.get(), harness.tailscale)
        XCTAssertEqual(elapsed, .milliseconds(180))
        XCTAssertLessThan(elapsed, .seconds(6))
    }

    func testBonjourWinsWithinLanGrace() async throws {
        let harness = try RouteHarness()
        harness.script = [harness.service: (.milliseconds(200), false), harness.tailscale: (.milliseconds(50), false)]
        let (result, elapsed) = await harness.race()
        XCTAssertEqual(try result.get(), harness.service)
        XCTAssertEqual(elapsed, .milliseconds(200))
        XCTAssertEqual(harness.browser.connectedRoute(for: "Mac"), nil)
    }

    func testTailscaleWinsAfterLanGraceExpires() async throws {
        let harness = try RouteHarness()
        harness.script = [harness.service: (.milliseconds(900), false), harness.tailscale: (.milliseconds(50), false)]
        let (result, elapsed) = await harness.race()
        XCTAssertEqual(try result.get(), harness.tailscale)
        XCTAssertEqual(elapsed, .milliseconds(400))
    }

    func testAllFailReportsOnceAfterLastCandidate() async throws {
        let harness = try RouteHarness()
        harness.script = [harness.service: (.milliseconds(10), true), harness.tailscale: (.milliseconds(20), true)]
        let (result, elapsed) = await harness.race()
        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertTrue(error.localizedDescription.contains("Local network"))
            XCTAssertTrue(error.localizedDescription.contains("100.90.189.102"))
        }
        XCTAssertEqual(elapsed, .milliseconds(120))
    }

    func testPathChangeDropsCachedRouteAndRacesAgain() async throws {
        let harness = try RouteHarness()
        var changes = 0
        let stop = harness.browser.onPathChange { changes += 1 }
        harness.script = [harness.service: (.milliseconds(10), true), harness.tailscale: (.milliseconds(80), false)]
        _ = await harness.race()
        harness.browser.recordResponse(from: harness.tailscale, for: "Mac")
        XCTAssertEqual(harness.browser.connectedRoute(for: "Mac"), "Tailscale")
        harness.started = []
        let cached = await harness.race()
        XCTAssertEqual(harness.started.first, harness.tailscale)
        XCTAssertEqual(cached.elapsed, .milliseconds(110))
        harness.browser.pathChanged()
        XCTAssertEqual(changes, 1)
        XCTAssertNil(harness.browser.connectedRoute(for: "Mac"))
        harness.script = [harness.service: (.milliseconds(30), false), harness.tailscale: (.milliseconds(80), true)]
        harness.started = []
        let after = await harness.race()
        XCTAssertEqual(harness.started.first, harness.service)
        XCTAssertEqual(try after.result.get(), harness.service)
        XCTAssertEqual(after.elapsed, .milliseconds(30))
        stop()
        harness.browser.pathChanged()
        XCTAssertEqual(changes, 1)
    }

    func testRouteLabelsAndKinds() throws {
        let harness = try RouteHarness(remote: "example.org")
        let remote = NWEndpoint.hostPort(host: "example.org", port: 47823)
        harness.browser.recordResponse(from: remote, for: "Mac")
        XCTAssertEqual(harness.browser.connectedRoute(for: "Mac"), "Remote address")
        harness.browser.recordResponse(from: harness.service, for: "Mac")
        XCTAssertEqual(harness.browser.connectedRoute(for: "Mac"), "Bonjour")
        harness.browser.recordResponse(from: .hostPort(host: "void.local", port: 47823), for: "Mac")
        XCTAssertEqual(harness.browser.connectedRoute(for: "Mac"), "Bonjour")
        XCTAssertEqual(MacBrowser.routeKind(.hostPort(host: "192.168.1.5", port: 1)), .lan)
        XCTAssertEqual(MacBrowser.routeKind(.hostPort(host: "mac.tail1.ts.net", port: 1)), .tailscale)
        XCTAssertEqual(MacBrowser.routeKind(.hostPort(host: "100.128.0.1", port: 1)), .other)
    }
}
