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

    static func testShortCapturePauses() {
        let ring = AudioRingBuffer()
        let output = UnsafeMutablePointer<Float>.allocate(capacity: 240)
        defer { output.deallocate() }
        for _ in 0..<12 { ring.pushPCM16(packet, isUSB: false) }
        for _ in 0..<6 {
            // 100 ms without capture or heartbeat, then the first resumed PCM frame.
            for _ in 0..<20 { ring.pull(left: output, right: nil, frameCount: 240) }
            ring.pushPCM16(packet, isUSB: false, captureResumed: true)
            for _ in 0..<11 { ring.pushPCM16(packet, isUSB: false) }
        }
        let idle = ring.diagnostics()
        check(idle.underruns == 0 && idle.targetMs == 20, "Short PC pauses inflated the LAN buffer")
        for _ in 0..<20 { ring.pull(left: output, right: nil, frameCount: 240) }
        ring.pushPCM16(packet, isUSB: false)
        check(ring.diagnostics().underruns == 1 && ring.diagnostics().targetMs == 25,
              "Unmarked network stall was not counted")
    }

    static func testRaisedBufferTargetDuringPlayback() {
        let ring = AudioRingBuffer()
        let output = UnsafeMutablePointer<Float>.allocate(capacity: 240)
        defer { output.deallocate() }
        for _ in 0..<12 { ring.pushPCM16(packet, isUSB: false) }
        ring.pull(left: output, right: nil, frameCount: 240)

        let bufferedMs = ring.diagnostics().bufferMs
        ring.setTargetMs(55)
        ring.pull(left: output, right: nil, frameCount: 240)
        let waiting = ring.diagnostics()
        check(waiting.targetMs == 55 && waiting.bufferMs == bufferedMs,
              "Raising the target did not hold buffered audio to refill")

        for _ in 0..<14 { ring.pushPCM16(packet, isUSB: false) }
        let refilled = ring.diagnostics().bufferMs
        ring.pull(left: output, right: nil, frameCount: 240)
        let resumed = ring.diagnostics()
        check(resumed.bufferMs < refilled && resumed.underruns == 0,
              "Playback did not resume cleanly after refilling")

        for _ in 0..<20 { ring.pull(left: output, right: nil, frameCount: 240) }
        ring.pushPCM16(packet, isUSB: false)
        check(ring.diagnostics().targetMs == 60, "Wi-Fi underrun did not raise the manual target")
        ring.setTargetMs(56)
        check(ring.diagnostics().targetMs == 60, "Raising the manual target reduced the existing buffer boost")
    }

    static func testAuthenticatedResumeMarker() {
        let key = SymmetricKey(data: Data(repeating: 3, count: 32))
        let session = LANSession(challenge: Data(), nonce: Data(), expiresAt: 25,
                                 key: key, lastAudioSeq: nil, lastHeartbeatSeq: nil)
        var header = Data(count: 28)
        header[4] = 42
        header[10] = 2
        var iv = Data(count: 12)
        iv[0] = 42
        let sealed = try! AES.GCM.seal(packet, using: key, nonce: AES.GCM.Nonce(data: iv), authenticating: header)
        check(session.decrypt(header + sealed.ciphertext + sealed.tag, prefixSize: 28,
                              payloadLength: packet.count, flags: 2) == packet,
              "Resume marker did not use the audio nonce domain")
        header[10] = 0
        check(session.decrypt(header + sealed.ciphertext + sealed.tag, prefixSize: 28,
                              payloadLength: packet.count, flags: 0) == nil,
              "Resume marker was not authenticated")
    }

    static func testReorderedAudio() {
        var reorder = AudioPacketReorder()
        func audio(_ seq: UInt32) -> AudioPacketReorder.Packet {
            .init(seq: seq, payload: packet, isUSB: false, captureResumed: false)
        }
        check(reorder.hold(audio(102), after: 100), "Could not hold an early packet")
        check(reorder.hold(audio(102), after: 100), "Duplicate escaped the reorder queue")
        check(reorder.next(after: 100, flush: false) == nil, "Queue skipped a packet before the deadline")
        check(reorder.next(after: 101, flush: false)?.seq == 102 && reorder.isEmpty,
              "Queue did not release exactly one packet after the missing packet arrived")
        check(reorder.hold(audio(103), after: 100) && reorder.next(after: 100, flush: true, before: 102) == nil,
              "A newer queued packet would skip the current packet during handoff")
        check(reorder.next(after: 102, flush: false)?.seq == 103 && reorder.isEmpty,
              "Queue did not resume after a handoff packet")
        check(!reorder.hold(audio(105), after: 100), "Queue accepted a packet outside the window")
        check(reorder.hold(audio(1), after: .max) && reorder.hold(audio(2), after: .max),
              "Queue did not handle sequence wrapping")
        check(reorder.next(after: .max, flush: true)?.seq == 1 &&
              reorder.next(after: 1, flush: false)?.seq == 2 && reorder.isEmpty,
              "Deadline did not release held packets in sequence order")

        let key = SymmetricKey(data: Data(repeating: 3, count: 32))
        var session = LANSession(challenge: Data(), nonce: Data(), expiresAt: 25,
                                 key: key, lastAudioSeq: nil, lastHeartbeatSeq: nil)
        check(session.accept(seq: .max - 1, heartbeat: false) && session.accept(seq: 0, heartbeat: false),
              "Audio sequence did not wrap")
        check(session.accept(seq: .max, heartbeat: false) && !session.accept(seq: .max, heartbeat: false),
              "Missing audio must be accepted once")
        check(!session.accept(seq: .max - 1, heartbeat: false) && !session.accept(seq: .max - 3, heartbeat: false),
              "Audio sequence accepted a duplicate or a packet outside the window")
        check(session.accept(seq: 7, heartbeat: true) && !session.accept(seq: 6, heartbeat: true),
              "Heartbeat must reject older sequences")
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

    static func testDrift(ppm: Double) {
        let ring = AudioRingBuffer()
        let output = UnsafeMutablePointer<Float>.allocate(capacity: 240)
        defer { output.deallocate() }
        for _ in 0..<8 { ring.pushPCM16(packet, isUSB: false) }
        let interval = 120 / (1 + ppm / 1_000_000)
        var arrival = interval + 37
        for frame in stride(from: 0, to: 48_000 * 60 * 30, by: 240) {
            while arrival <= Double(frame) {
                ring.pushPCM16(packet, isUSB: false)
                arrival += interval
            }
            ring.pull(left: output, right: nil, frameCount: 240)
        }
        // Classify any final pending underrun as a stall, then inspect the counters.
        ring.pushPCM16(packet, isUSB: false)
        let result = ring.diagnostics()
        check(result.underruns == 0 && result.trimmedFrames == 0,
              "30 min at \(ppm) ppm: \(result.underruns) underruns, \(result.trimmedFrames) trimmed frames")
    }

    static func main() {
        testUnderruns()
        testShortCapturePauses()
        testRaisedBufferTargetDuringPlayback()
        testAuthenticatedResumeMarker()
        testReorderedAudio()
        testSessions()
        testDrift(ppm: -200)
        testDrift(ppm: 200)
        print("Swift underrun, adaptive-buffer, session and 30-minute drift tests passed.")
    }
}
