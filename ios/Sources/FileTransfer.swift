import CryptoKit
import Foundation
import Network

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

    static func upload(_ file: URL, endpoint: NWEndpoint, key: Data,
                       progress: @escaping @Sendable (Progress) -> Void) async throws {
        let securityScope = file.startAccessingSecurityScopedResource()
        defer { if securityScope { file.stopAccessingSecurityScopedResource() } }
        let offer = try await Offer(file: file)
        let channel = FileChannel(endpoint: endpoint, pairingKey: key)
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
            let transferStart = ProcessInfo.processInfo.systemUptime
            try await channel.send(Data([4]) + data)
            try await BulkTraffic.shared.pace(bytes: data.count, since: transferStart)
            completed += UInt64(data.count)
            report(completed, offer.size, resumed, start, &lastProgress, progress)
        }
        try await channel.send(Data([5]))
        guard try await channel.receive() == Data([6]) else { throw FileTransferError.invalidReply }
    }

    static func download(endpoint: NWEndpoint, key: Data,
                         progress: @escaping @Sendable (Progress) -> Void) async throws -> URL {
        let channel = FileChannel(endpoint: endpoint, pairingKey: key)
        defer { channel.close() }
        try await channel.authenticate()
        try await channel.send(Data([2]))
        let offer = try await Offer(reply: channel.receive())
        let manager = FileManager.default
        let folder = try manager.url(for: .documentDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true).appendingPathComponent("NiKAudio")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let basename = safeFilename(offer.name)
        var target = folder.appendingPathComponent(basename)
        var index = 1
        while manager.fileExists(atPath: target.path) {
            let values = try target.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values.isRegularFile == true, let size = values.fileSize, UInt64(size) == offer.size,
               try await digest(of: target, keepAlive: channel) == offer.digest {
                try await channel.send(Data([3]) + Data(fileLE: offer.size))
                guard try await channel.receive() == Data([5]) else { throw FileTransferError.invalidReply }
                try? await channel.send(Data([6]))
                return target
            }
            target = folder.appendingPathComponent("\(index) - \(basename)")
            index += 1
        }
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
            let transferStart = ProcessInfo.processInfo.systemUptime
            let data = try await channel.receive()
            guard data.first == 4, data.count > 1, UInt64(data.count - 1) <= offer.size - completed else {
                throw FileTransferError.invalidReply
            }
            try fileHandle.write(contentsOf: data.dropFirst())
            try await BulkTraffic.shared.pace(bytes: data.count - 1, since: transferStart)
            completed += UInt64(data.count - 1)
            report(completed, offer.size, resumed, start, &lastProgress, progress)
        }
        try fileHandle.close()
        guard try await channel.receive() == Data([5]) else { throw FileTransferError.invalidReply }
        guard try await digest(of: partial, keepAlive: channel) == offer.digest else {
            try? manager.removeItem(at: partial)
            throw FileTransferError.integrity
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
