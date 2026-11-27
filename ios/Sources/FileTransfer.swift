import CryptoKit
import Foundation
import Network

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

enum FileTransfer {
    static let port: UInt16 = 55124
    static let block = 256 * 1024
    static let maxBytes: UInt64 = 1 << 40

    struct Progress: Sendable {
        let total: UInt64
        let completed: UInt64
        let bytesPerSecond: Double
    }

    private struct Offer {
        let name: String
        let size: UInt64
        let digest: Data

        var uploadRequest: Data {
            let filename = Data(name.utf8)
            return Data([1]) + Data(fileLE: size) + Data(fileLE: UInt16(filename.count)) + digest + filename
        }

        init(file: URL) async throws {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let bytes = values.fileSize, bytes >= 0,
                  UInt64(bytes) <= maxBytes, (1...1000).contains(file.lastPathComponent.utf8.count) else {
                throw FileTransferError.missingFile
            }
            name = file.lastPathComponent
            size = UInt64(bytes)
            digest = try await FileTransfer.digest(of: file)
        }

        init(reply: Data) throws {
            guard reply.first == 7, reply.count >= 44 else { throw FileTransferError.invalidReply }
            size = reply.fileLE(at: 1)
            let length: UInt16 = reply.fileLE(at: 9)
            guard size <= maxBytes, (1...1000).contains(length), reply.count == 43 + Int(length),
                  let name = String(data: reply.dropFirst(43), encoding: .utf8) else {
                throw FileTransferError.invalidReply
            }
            self.name = name
            digest = Data(reply.dropFirst(11).prefix(32))
        }
    }

    static func upload(_ file: URL, address: String, key: Data,
                       progress: @escaping @Sendable (Progress) -> Void) async throws {
        let securityScope = file.startAccessingSecurityScopedResource()
        defer { if securityScope { file.stopAccessingSecurityScopedResource() } }
        let offer = try await Offer(file: file)
        let channel = try FileChannel(address: address, pairingKey: key)
        defer { channel.close() }
        try await channel.authenticate()
        try await channel.send(offer.uploadRequest)
        let reply = try await channel.receive()
        guard reply.count == 9, reply.first == 3 else { throw FileTransferError.invalidReply }
        var completed: UInt64 = reply.fileLE(at: 1)
        guard completed <= offer.size else { throw FileTransferError.invalidReply }
        let fileHandle = try FileHandle(forReadingFrom: file)
        defer { try? fileHandle.close() }
        try fileHandle.seek(toOffset: completed)
        let resumed = completed
        let start = ProcessInfo.processInfo.systemUptime
        var lastProgress = start - 1
        while completed < offer.size {
            try Task.checkCancellation()
            let count = Int(min(UInt64(block), offer.size - completed))
            guard let data = try fileHandle.read(upToCount: count), !data.isEmpty else {
                throw FileTransferError.missingFile
            }
            try await channel.send(Data([4]) + data)
            completed += UInt64(data.count)
            report(completed, offer.size, resumed, start, &lastProgress, progress)
        }
        try await channel.send(Data([5]))
        guard try await channel.receive() == Data([6]) else { throw FileTransferError.invalidReply }
    }

    static func download(address: String, key: Data,
                         progress: @escaping @Sendable (Progress) -> Void) async throws -> URL {
        let channel = try FileChannel(address: address, pairingKey: key)
        defer { channel.close() }
        try await channel.authenticate()
        try await channel.send(Data([2]))
        let offer = try await Offer(reply: channel.receive())
        let manager = FileManager.default
        let parts = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true).appendingPathComponent("FileTransfers")
        try manager.createDirectory(at: parts, withIntermediateDirectories: true)
        let identifier = offer.digest.map { String(format: "%02x", $0) }.joined()
        let partial = parts.appendingPathComponent(identifier + ".part")
        var completed = UInt64((try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        if completed > offer.size {
            try manager.removeItem(at: partial)
            completed = 0
        }
        if !manager.fileExists(atPath: partial.path) {
            guard manager.createFile(atPath: partial.path, contents: nil) else { throw FileTransferError.missingFile }
        }
        let fileHandle = try FileHandle(forWritingTo: partial)
        defer { try? fileHandle.close() }
        try fileHandle.seek(toOffset: completed)
        try await channel.send(Data([3]) + Data(fileLE: completed))
        let resumed = completed
        let start = ProcessInfo.processInfo.systemUptime
        var lastProgress = start - 1
        while completed < offer.size {
            try Task.checkCancellation()
            let data = try await channel.receive()
            guard data.first == 4, data.count > 1, UInt64(data.count - 1) <= offer.size - completed else {
                throw FileTransferError.invalidReply
            }
            try fileHandle.write(contentsOf: data.dropFirst())
            completed += UInt64(data.count - 1)
            report(completed, offer.size, resumed, start, &lastProgress, progress)
        }
        try fileHandle.close()
        guard try await channel.receive() == Data([5]) else { throw FileTransferError.invalidReply }
        guard try await digest(of: partial, keepAlive: channel) == offer.digest else {
            try? manager.removeItem(at: partial)
            throw FileTransferError.integrity
        }
        let folder = try manager.url(for: .documentDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true).appendingPathComponent("NiKAudio")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let basename = safeFilename(offer.name)
        var target = folder.appendingPathComponent(basename)
        var index = 1
        while manager.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(index) - \(basename)")
            index += 1
        }
        try manager.moveItem(at: partial, to: target)
        // The file is already saved if the peer disconnects before receiving the final acknowledgement.
        try? await channel.send(Data([6]))
        return target
    }

    private static func digest(of file: URL, keepAlive channel: FileChannel? = nil) async throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        var lastKeepAlive = ProcessInfo.processInfo.systemUptime
        while let bytes = try handle.read(upToCount: block), !bytes.isEmpty {
            try Task.checkCancellation()
            hash.update(data: bytes)
            if let channel = channel {
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastKeepAlive >= 5 {
                    try await channel.send(Data([8]))
                    lastKeepAlive = now
                }
            }
        }
        return Data(hash.finalize())
    }

    private static func safeFilename(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        var byteCount = 0
        for scalar in name.unicodeScalars {
            let value: Unicode.Scalar = forbidden.contains(scalar) ? "_" : scalar
            byteCount += value.utf8.count
            if byteCount > 180 { break }
            scalars.append(value)
        }
        let clean = String(scalars)
        return clean.isEmpty || clean.hasPrefix(".") ? "NiKAudio - " + clean : clean
    }

    private static func report(_ completed: UInt64, _ total: UInt64, _ offset: UInt64, _ start: Double,
                               _ last: inout Double, _ callback: (Progress) -> Void) {
        let now = ProcessInfo.processInfo.systemUptime
        guard completed == total || now - last >= 0.15 else { return }
        last = now
        callback(Progress(total: total, completed: completed,
                          bytesPerSecond: Double(completed - offset) / max(now - start, 0.01)))
    }
}

private final class FileChannel {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "NiKAudio.file-transfer")
    private let pairingKey: SymmetricKey
    private var sender: SymmetricKey?
    private var receiver: SymmetricKey?
    private var sendCounter: UInt32 = 0
    private var receiveCounter: UInt32 = 0

    init(address: String, pairingKey: Data) throws {
        guard let ip = IPv4Address(address), let port = NWEndpoint.Port(rawValue: FileTransfer.port) else {
            throw FileTransferError.invalidAddress
        }
        self.pairingKey = SymmetricKey(data: pairingKey)
        let params = NWParameters.tcp
        params.serviceClass = .background
        connection = NWConnection(host: .ipv4(ip), port: port, using: params)
        connection.start(queue: queue)
    }

    func close() { connection.cancel() }

    func authenticate() async throws {
        guard let nonce = LANPairing.randomBytes(count: 16) else { throw FileTransferError.invalidReply }
        let hello = Data("NIKF".utf8) + Data([1]) + nonce
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
        guard let sender = sender, !data.isEmpty, data.count <= FileTransfer.block + 1,
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
        guard size > 0 && size <= FileTransfer.block + 1 else { throw FileTransferError.invalidReply }
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
        queue.asyncAfter(deadline: .now() + 30, execute: item)
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

private extension Data {
    init<T: FixedWidthInteger>(fileLE value: T) {
        var bytes = value.littleEndian
        self = Swift.withUnsafeBytes(of: &bytes) { Data($0) }
    }

    func fileLE<T: FixedWidthInteger>(at offset: Int) -> T {
        withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
    }
}
