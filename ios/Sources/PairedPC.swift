import Foundation
import Network

enum PairedPC {
    static let fileService = "_nikaudio._tcp"

    struct Destination: Sendable {
        let endpoint: NWEndpoint
        let name: String?
    }

    static func find(address: String, preferred: String, key: Data) async throws -> Destination {
        if let manual = IPv4Address(address) {
            let endpoint = NWEndpoint.hostPort(host: .ipv4(manual), port: NWEndpoint.Port(rawValue: 55124)!)
            if try await accepts(endpoint, key: key) { return Destination(endpoint: endpoint, name: nil) }
        } else if !address.isEmpty {
            throw FileTransferError.invalidAddress
        }

        let services = await browse()
        let sorted = services.sorted { $0.name == preferred && $1.name != preferred }
        for service in sorted.prefix(8) {
            try Task.checkCancellation()
            if try await accepts(service.endpoint, key: key) { return service }
        }
        throw FileTransferError.remote("Không tìm thấy PC đã ghép đôi. Kiểm tra Wi-Fi hoặc nhập IP của Windows.")
    }

    private static func accepts(_ endpoint: NWEndpoint, key: Data) async throws -> Bool {
        let channel = FileChannel(endpoint: endpoint, pairingKey: key, timeout: 2.5)
        defer { channel.close() }
        do {
            try await channel.authenticate()
            try await channel.send(Data([11]))
            return try await channel.receive() == Data([12])
        } catch {
            try Task.checkCancellation()
            return false
        }
    }

    private static func browse() async -> [Destination] {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "NiKAudio.Bonjour")
            let browser = NWBrowser(for: .bonjour(type: fileService, domain: "local."), using: .tcp)
            var destinations: [Destination] = []
            browser.browseResultsChangedHandler = { results, _ in
                destinations = results.compactMap {
                    guard case .service(let name, _, _, _) = $0.endpoint else { return nil }
                    return Destination(endpoint: $0.endpoint, name: name)
                }
            }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 2) {
                browser.browseResultsChangedHandler = nil
                browser.cancel()
                continuation.resume(returning: destinations)
            }
        }
    }
}
