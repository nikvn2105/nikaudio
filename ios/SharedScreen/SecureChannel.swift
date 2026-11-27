import CryptoKit
import Foundation
import Network
import Security

enum FileTransferError: LocalizedError {
    case invalidAddress, invalidReply, missingFile, connectionLost, integrity, remote(String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "Nhập đúng địa chỉ IPv4 của máy Windows."
        case .invalidReply: return "Không xác thực được máy tính hoặc phản hồi không hợp lệ."
        case .missingFile: return "Không đọc được tệp hoặc tệp vượt giới hạn."
        case .connectionLost: return "Mất kết nối với máy tính. Thử lại để tiếp tục."
        case .integrity: return "Tệp không khớp mã kiểm tra. Hãy thử gửi lại."
        case .remote(let message): return message
        }
    }
}

final class FileChannel {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "NiKAudio.file-transfer")
    private let pairingKey: SymmetricKey
    private let magic: String
    private let operationTimeout: TimeInterval
    private let maxRecord = 256 * 1024 + 1
    private var sender: SymmetricKey?
    private var receiver: SymmetricKey?
    private var sendCounter: UInt32 = 0
    private var receiveCounter: UInt32 = 0

    init(endpoint: NWEndpoint, pairingKey: Data, magic: String = "NIKF",
         timeout: TimeInterval = 30, background: Bool = true) {
        self.pairingKey = SymmetricKey(data: pairingKey)
        self.magic = magic
        operationTimeout = timeout
        let params = NWParameters.tcp
        if background { params.serviceClass = .background }
        connection = NWConnection(to: endpoint, using: params)
        connection.start(queue: queue)
    }

    convenience init(address: String, pairingKey: Data) throws {
        guard let ip = IPv4Address(address) else { throw FileTransferError.invalidAddress }
        self.init(endpoint: .hostPort(host: .ipv4(ip), port: NWEndpoint.Port(rawValue: 55124)!),
                  pairingKey: pairingKey)
    }

    func close() { connection.cancel() }

    func authenticate() async throws {
        var nonce = Data(count: 16)
        let status = nonce.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, 16, bytes.baseAddress!)
        }
        guard status == errSecSuccess else { throw FileTransferError.invalidReply }
        let hello = Data(magic.utf8) + Data([1]) + nonce
        try await write(hello)
        let reply = try await read(count: 48)
        let transcript = hello + reply.prefix(16)
        guard HMAC<SHA256>.isValidAuthenticationCode(reply.suffix(32), authenticating: transcript + Data([0]),
                                                    using: pairingKey) else {
            throw FileTransferError.invalidReply
        }
        func derive(_ role: UInt8) -> SymmetricKey {
            SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: transcript + Data([role]), using: pairingKey)))
        }
        sender = derive(1)
        receiver = derive(2)
    }

    func send(_ data: Data) async throws {
        guard let sender = sender, !data.isEmpty, data.count <= maxRecord,
              sendCounter != UInt32.max else { throw FileTransferError.invalidReply }
        let header = Data(fileLE: UInt32(data.count))
        let box = try AES.GCM.seal(data, using: sender, nonce: nonce(sendCounter), authenticating: header)
        sendCounter += 1
        try await write(header + box.ciphertext + box.tag)
    }

    func receive() async throws -> Data {
        while true {
            let data = try await receiveRecord()
            if data != Data([8]) { return data }
        }
    }

    private func receiveRecord() async throws -> Data {
        guard let receiver = receiver, receiveCounter != UInt32.max else { throw FileTransferError.invalidReply }
        let header = try await read(count: 4)
        let size: UInt32 = header.fileLE(at: 0)
        guard size > 0 && size <= maxRecord else { throw FileTransferError.invalidReply }
        let payload = try await read(count: Int(size) + 16)
        let box = try AES.GCM.SealedBox(nonce: nonce(receiveCounter), ciphertext: payload.dropLast(16),
                                       tag: payload.suffix(16))
        let data = try AES.GCM.open(box, using: receiver, authenticating: header)
        receiveCounter += 1
        if data.first == 255 {
            throw FileTransferError.remote(String(decoding: data.dropFirst(), as: UTF8.self))
        }
        return data
    }

    private func nonce(_ counter: UInt32) throws -> AES.GCM.Nonce {
        try AES.GCM.Nonce(data: Data(fileLE: counter) + Data(count: 8))
    }

    private func deadline() -> DispatchWorkItem {
        let item = DispatchWorkItem { [connection] in connection.cancel() }
        queue.asyncAfter(deadline: .now() + operationTimeout, execute: item)
        return item
    }

    private func write(_ data: Data) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let timer = deadline()
                connection.send(content: data, completion: .contentProcessed { error in
                    timer.cancel()
                    if error != nil { continuation.resume(throwing: FileTransferError.connectionLost) }
                    else { continuation.resume() }
                })
            }
        } onCancel: { [connection] in connection.cancel() }
    }

    private func read(count: Int) async throws -> Data {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timer = deadline()
                connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                    timer.cancel()
                    if error == nil, let data = data, data.count == count { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: FileTransferError.connectionLost) }
                }
            }
        } onCancel: { [connection] in connection.cancel() }
    }
}

extension Data {
    init<T: FixedWidthInteger>(fileLE value: T) {
        var bytes = value.littleEndian
        self = Swift.withUnsafeBytes(of: &bytes) { Data($0) }
    }

    func fileLE<T: FixedWidthInteger>(at offset: Int) -> T {
        withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
    }
}
