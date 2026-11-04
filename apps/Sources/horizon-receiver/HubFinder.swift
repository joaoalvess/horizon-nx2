import Foundation
import HorizonLink
import Network

final class HubFinder: @unchecked Sendable {
    struct Found: Sendable {
        let name: String
        let endpoint: NWEndpoint
    }

    private let queue = DispatchQueue(label: "dev.joaoalvess.horizon.receiver.finder")
    private var browser: NWBrowser?
    private var found: [String: NWEndpoint] = [:]
    private var firstSeen: DispatchTime?
    private var done = false

    func find(name: String?, timeout: TimeInterval = 10, settle: TimeInterval = 1.5, completion: @escaping @Sendable (Result<Found, OptionError>) -> Void) {
        queue.async { [self] in
            let parameters = NWParameters()
            parameters.includePeerToPeer = false
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: LinkProtocol.serviceType, domain: nil), using: parameters)
            self.browser = browser
            browser.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .failed(let error) = state {
                    finish(.failure(OptionError(message: "the Bonjour search failed: \(error)")), completion)
                }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                guard let self else { return }
                for result in results {
                    if case .service(let service, _, _, _) = result.endpoint, found[service] == nil { found[service] = result.endpoint }
                }
                decide(name: name, final: false, completion)
                if firstSeen == nil, !found.isEmpty {
                    firstSeen = .now()
                    queue.asyncAfter(deadline: .now() + settle) { [weak self] in self?.decide(name: name, final: true, completion) }
                }
            }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                decide(name: name, final: true, completion)
                let reason = found.isEmpty
                    ? "no Mac running HorizonHub showed up on Bonjour in \(Int(timeout)) s (is the app open? is local network access allowed?)"
                    : "no Mac named \(name ?? "") among: \(found.keys.sorted().joined(separator: ", "))"
                finish(.failure(OptionError(message: reason)), completion)
            }
        }
    }

    private func decide(name: String?, final: Bool, _ completion: @escaping @Sendable (Result<Found, OptionError>) -> Void) {
        if let name {
            if let endpoint = found[name] { finish(.success(Found(name: name, endpoint: endpoint)), completion) }
            return
        }
        guard final, !found.isEmpty else { return }
        if found.count == 1, let (only, endpoint) = found.first {
            finish(.success(Found(name: only, endpoint: endpoint)), completion)
        } else {
            let names = found.keys.sorted().joined(separator: ", ")
            finish(.failure(OptionError(message: "more than one Mac found (\(names)); pick one with --hub-name")), completion)
        }
    }

    private func finish(_ result: Result<Found, OptionError>, _ completion: @escaping @Sendable (Result<Found, OptionError>) -> Void) {
        guard !done else { return }
        done = true
        browser?.cancel()
        browser = nil
        completion(result)
    }
}
