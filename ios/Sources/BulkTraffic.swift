import Foundation

// Called from network/transfer tasks only, independently of the audio render callback.
final class BulkTraffic: @unchecked Sendable {
    static let shared = BulkTraffic()
    private let lock = NSLock()
    private var lanActive = false
    private var limitedUntil = 0.0
    private var previousUnderruns = 0

    func update(lanActive: Bool, underruns: Int) {
        lock.lock()
        defer { lock.unlock() }
        self.lanActive = lanActive
        if lanActive && underruns > previousUnderruns {
            limitedUntil = ProcessInfo.processInfo.systemUptime + 8
        }
        previousUnderruns = underruns
    }

    private func rate() -> Double? {
        lock.lock()
        defer { lock.unlock() }
        guard lanActive else { return nil }
        return ProcessInfo.processInfo.systemUptime < limitedUntil ? 2_097_152 : 8_388_608
    }

    func pace(bytes: Int, since start: TimeInterval) async throws {
        guard let rate = rate() else { return }
        let remaining = Double(bytes) / rate - (ProcessInfo.processInfo.systemUptime - start)
        if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
    }
}
