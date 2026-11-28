import CryptoKit
import Foundation

struct LANSession {
    let challenge: Data
    let nonce: Data
    let expiresAt: TimeInterval
    let key: SymmetricKey
    var lastAudioSeq: UInt32?
    var lastHeartbeatSeq: UInt32?
    var recentAudio: UInt8 = 0

    func decrypt(_ packet: Data, prefixSize: Int, payloadLength: Int, flags: UInt16) -> Data? {
        var iv = Data(count: 12)
        iv.replaceSubrange(0..<4, with: packet.dropFirst(4).prefix(4))
        // Audio flags stay in the authenticated header; only heartbeat uses the other IV domain.
        iv[4] = flags == 1 ? 1 : 0
        do {
            let gcmNonce = try AES.GCM.Nonce(data: iv)
            let box = try AES.GCM.SealedBox(nonce: gcmNonce,
                                            ciphertext: packet.dropFirst(prefixSize).prefix(payloadLength),
                                            tag: packet.suffix(16))
            return try AES.GCM.open(box, using: key, authenticating: packet.prefix(prefixSize))
        } catch {
            return nil
        }
    }

    mutating func accept(seq: UInt32, heartbeat: Bool) -> Bool {
        if heartbeat {
            if let last = lastHeartbeatSeq, Int32(bitPattern: seq &- last) <= 0 { return false }
            lastHeartbeatSeq = seq
            return true
        }
        if let last = lastAudioSeq {
            let delta = Int32(bitPattern: seq &- last)
            if delta <= 0 {
                // Accept a missing audio packet once, within the playback reorder window.
                guard delta >= -AudioPacketReorder.maxAhead else { return false }
                let bit: UInt8 = 1 << -delta
                guard recentAudio & bit == 0 else { return false }
                recentAudio |= bit
                return true
            }
            recentAudio <<= min(delta, 8)
        }
        lastAudioSeq = seq
        recentAudio |= 1
        return true
    }
}

struct LANSessionTable {
    private let capacity = 12
    private var sessions: [Data: LANSession] = [:]
    private var activeAudioNonce: Data?

    mutating func clear() {
        sessions.removeAll()
        activeAudioNonce = nil
    }

    mutating func session(for challenge: Data, now: TimeInterval, make: () -> LANSession?) -> LANSession? {
        sessions = sessions.filter { now < $0.value.expiresAt }
        if let existing = sessions.values.first(where: { $0.challenge == challenge }) { return existing }
        guard let session = make() else { return nil }
        if sessions.count >= capacity,
           let oldest = sessions.filter({ $0.key != activeAudioNonce }).min(by: {
               $0.value.expiresAt < $1.value.expiresAt
           })?.key {
            sessions.removeValue(forKey: oldest)
        }
        sessions[session.nonce] = session
        return session
    }

    func lookup(_ nonce: Data, now: TimeInterval) -> LANSession? {
        guard let session = sessions[nonce], now < session.expiresAt else { return nil }
        return session
    }

    mutating func update(_ session: LANSession, audio: Bool) {
        sessions[session.nonce] = session
        if audio { activeAudioNonce = session.nonce }
    }
}
