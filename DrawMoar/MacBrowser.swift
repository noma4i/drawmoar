import CompanionKit
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
    private let browser = NWBrowser(for: .bonjour(type: bonjourServiceType, domain: nil), using: .tcp)

    init() {
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let macs = results.compactMap { result -> Mac? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return Mac(name: name, endpoint: result.endpoint)
            }.sorted { $0.name < $1.name }
            Task { @MainActor in self?.macs = macs }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case let .failed(error) = state {
                Task { @MainActor in self?.error = error.localizedDescription }
            }
        }
        browser.start(queue: .main)
    }

    deinit { browser.cancel() }
}
