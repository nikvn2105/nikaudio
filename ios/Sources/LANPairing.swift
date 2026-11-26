import CryptoKit
import Foundation
import Security

enum LANPairing {
    static let keySize = 32
    static let nonceSize = 16
    static let tagSize = 32
    static let cipherTagSize = 16

    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.nikvn2105.nikaudio",
        kSecAttrAccount as String: "lan-pairing"
    ]

    static func randomBytes(count: Int) -> Data? {
        var bytes = Data(count: count)
        let result = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        return result == errSecSuccess ? bytes : nil
    }

    static func key() throws -> Data {
        var lookup = query
        lookup[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, let key = result as? Data, key.count == keySize { return key }
        guard status == errSecItemNotFound else { throw storageError(status) }
        return try renewKey()
    }

    static func renewKey() throws -> Data {
        guard let bytes = randomBytes(count: keySize) else { throw storageError(errSecNotAvailable) }
        let values = [kSecValueData as String: bytes]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var entry = query
            entry[kSecValueData as String] = bytes
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(entry as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw storageError(status) }
        return bytes
    }

    static func storageError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Không lưu hoặc đọc được khóa ghép đôi (\(status))."])
    }
}

struct LANSession {
    let challenge: Data
    let nonce: Data
    let expiresAt: TimeInterval
    let key: SymmetricKey
    var lastAudioSeq: UInt32?
    var lastHeartbeatSeq: UInt32?

    func decrypt(_ packet: Data, prefixSize: Int, payloadLength: Int, flags: UInt16) -> Data? {
        var iv = Data(count: 12)
        iv.replaceSubrange(0..<4, with: packet.dropFirst(4).prefix(4))
        iv[4] = UInt8(flags)
        do {
            let gcmNonce = try AES.GCM.Nonce(data: iv)
            let box = try AES.GCM.SealedBox(nonce: gcmNonce,
                                            ciphertext: packet.dropFirst(prefixSize).prefix(payloadLength),
                                            tag: packet.suffix(LANPairing.cipherTagSize))
            return try AES.GCM.open(box, using: key, authenticating: packet.prefix(prefixSize))
        } catch {
            return nil
        }
    }

    mutating func accept(seq: UInt32, heartbeat: Bool) -> Bool {
        let last = heartbeat ? lastHeartbeatSeq : lastAudioSeq
        if let last = last, Int32(bitPattern: seq &- last) <= 0 { return false }
        if heartbeat { lastHeartbeatSeq = seq } else { lastAudioSeq = seq }
        return true
    }
}
