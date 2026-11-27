import CryptoKit
import Foundation

@main
struct AudioCoreTests {
    static let packet = Data(repeating: 0, count: 480)

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(1)
        }
    }

    static func testUnderruns() {
        let ring = AudioRingBuffer()
        let output = UnsafeMutablePointer<Float>.allocate(capacity: 240)
        defer { output.deallocate() }
        func fill() { for _ in 0..<12 { ring.pushPCM16(packet, isUSB: false) } }
        func drain() { for _ in 0..<8 { ring.pull(left: output, right: nil, frameCount: 240) } }

        fill()
        drain()
        ring.markSenderIdle()
        fill()
        check(ring.diagnostics().underruns == 0, "An idle heartbeat counted as an underrun")

        drain()
        check(ring.diagnostics().underruns == 0, "An unresolved underrun was counted too early")
        ring.pushPCM16(packet, isUSB: false)
        let stalled = ring.diagnostics()
        check(stalled.underruns == 1 && stalled.targetMs == 25, "A LAN stall did not increase the buffer")
        ring.markSenderIdle()
        ring.updateAdaptiveTarget(activeLAN: false, elapsed: 1)
        check(ring.diagnostics().targetMs == 25, "Idle telemetry reset the adaptive buffer")
        ring.pushPCM16(packet, isUSB: true)
        check(ring.diagnostics().targetMs == 20, "USB did not reset the LAN buffer boost")
    }

    static func testSessions() {
        var table = LANSessionTable()
        let key = SymmetricKey(data: Data(repeating: 1, count: 32))
        func create(_ value: UInt8, now: Double, table: inout LANSessionTable) -> LANSession? {
            let index = Data([value])
            return table.session(for: index, now: now) {
                LANSession(challenge: index, nonce: index, expiresAt: now + 25, key: key,
                           lastAudioSeq: nil, lastHeartbeatSeq: nil)
            }
        }
        let first = create(1, now: 0, table: &table)!
        table.update(first, audio: true)
        for i in UInt8(2)...12 { check(create(i, now: Double(i), table: &table) != nil, "Could not fill LAN table") }
        check(create(13, now: 13, table: &table) != nil, "Full LAN table rejected a new session")
        check(table.lookup(Data([1]), now: 13) != nil, "Active LAN session was evicted")
        check(table.lookup(Data([2]), now: 13) == nil, "Oldest inactive LAN session survived eviction")
        check(table.lookup(Data([1]), now: 26) == nil, "Expired active session bypassed expiration")
    }

    static func main() {
        testUnderruns()
        testSessions()
        print("Swift underrun, adaptive-buffer and session tests passed.")
    }
}
