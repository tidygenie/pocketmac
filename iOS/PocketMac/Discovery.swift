import Foundation
import Network

/// Finds PocketMac hosts nearby over Bonjour — same Wi-Fi, or directly over
/// Apple peer-to-peer Wi-Fi (AWDL) when there is no router at all.
final class Discovery: ObservableObject {
    static let shared = Discovery()

    struct Found: Identifiable, Equatable {
        var id: String          // Mac ID from the TXT record
        var name: String
        var endpoint: NWEndpoint
    }

    @Published private(set) var found: [String: Found] = [:]
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: PocketMacBonjourType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            var map = [String: Found]()
            for r in results {
                guard case let .service(name, _, _, _) = r.endpoint else { continue }
                var id = ""
                if case let .bonjour(txt) = r.metadata, let v = txt["id"] { id = DeviceID.normalize(v) }
                guard !id.isEmpty else { continue }
                map[id] = Found(id: id, name: name, endpoint: r.endpoint)
            }
            DispatchQueue.main.async { self?.found = map }
        }
        b.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.stop(); self?.start() }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }
}
