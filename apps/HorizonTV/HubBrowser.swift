import Foundation
import HorizonLink
import Network

struct DiscoveredHub: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var endpoint: NWEndpoint
    var compatible: Bool
}

final class HubBrowser: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.joaoalvess.horizon.tv.browser")
    private let update: @Sendable ([DiscoveredHub]) -> Void
    private var browser: NWBrowser?
    private var stopped = false

    init(update: @escaping @Sendable ([DiscoveredHub]) -> Void) {
        self.update = update
    }

    func start() {
        queue.async { [self] in
            stopped = false
            begin()
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            browser?.cancel()
            browser = nil
        }
    }

    private func begin() {
        guard !stopped, browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: LinkProtocol.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [update] results, _ in
            update(results.compactMap(Self.hub).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
        browser.stateUpdateHandler = { [weak self] state in
            guard let self, case .failed = state else { return }
            self.browser?.cancel()
            self.browser = nil
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.begin() }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    static func hub(_ result: NWBrowser.Result) -> DiscoveredHub? {
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        var id = name
        var compatible = true
        if case .bonjour(let record) = result.metadata {
            if let hubId = record["id"], !hubId.isEmpty { id = hubId }
            if let version = record["v"] { compatible = version == String(LinkProtocol.version) }
        }
        return DiscoveredHub(id: id, name: name, endpoint: result.endpoint, compatible: compatible)
    }
}
