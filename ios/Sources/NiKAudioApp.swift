import SwiftUI
import CryptoKit
import AVFAudio
import Network
import Darwin

// MARK: - UnfairLock Stereo Float Ring Buffer (48kHz)

final class AudioRingBuffer {
    private let capacityFrames: Int
    private let buffer: UnsafeMutablePointer<Float>
    private var readIndex: Int = 0
    private var writeIndex: Int = 0
    private var availableFrames: Int = 0
    private let lock: UnsafeMutablePointer<os_unfair_lock>

    private var requestedFrames = 960 // 20ms @ 48kHz
    private var adaptiveFrames = 0
    private var lastUnderrunCheck = 0
    private var stableTime: TimeInterval = 0
    private var minimumRenderFrames = 0
    private var targetFrames: Int { min(capacityFrames, max(requestedFrames + adaptiveFrames, minimumRenderFrames)) }
    private var maxFrames: Int { min(capacityFrames, max(targetFrames * 2 + 480, 2400)) }
    private var primed: Bool = false
    private var underruns = 0
    private var fadeInFrames = 0

    private var lastL: Float = 0
    private var lastR: Float = 0

    init(capacityFrames: Int = 16384) {
        self.capacityFrames = capacityFrames
        self.buffer = UnsafeMutablePointer<Float>.allocate(capacity: capacityFrames * 2)
        self.buffer.initialize(repeating: 0, count: capacityFrames * 2)
        self.lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        self.lock.initialize(to: os_unfair_lock())
    }

    deinit {
        buffer.deallocate()
        lock.deallocate()
    }

    func setTargetMs(_ ms: Double) {
        os_unfair_lock_lock(lock)
        let clamped = max(10.0, min(60.0, ms))
        requestedFrames = Int((clamped / 1000.0) * 48000.0)
        adaptiveFrames = 0
        stableTime = 0
        lastUnderrunCheck = underruns
        os_unfair_lock_unlock(lock)
    }

    func reset() {
        os_unfair_lock_lock(lock)
        readIndex = 0
        writeIndex = 0
        availableFrames = 0
        minimumRenderFrames = 0
        underruns = 0
        lastUnderrunCheck = 0
        adaptiveFrames = 0
        stableTime = 0
        fadeInFrames = 0
        primed = false
        lastL = 0
        lastR = 0
        os_unfair_lock_unlock(lock)
    }

    func diagnostics() -> (bufferMs: Double, targetMs: Double, underruns: Int) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return (Double(availableFrames) / 48, Double(targetFrames) / 48, underruns)
    }

    func updateAdaptiveTarget(activeLAN: Bool, elapsed: TimeInterval) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        let newUnderruns = underruns - lastUnderrunCheck
        lastUnderrunCheck = underruns
        guard activeLAN else {
            if !primed { adaptiveFrames = 0 }
            stableTime = 0
            return
        }

        if newUnderruns > 0 {
            // Add 5 ms of network headroom, up to 30 ms above the selected target.
            adaptiveFrames = min(1440, adaptiveFrames + 240)
            stableTime = 0
        } else {
            stableTime += elapsed
            if stableTime >= 20 {
                adaptiveFrames = max(0, adaptiveFrames - 96)
                stableTime = 0
            }
        }
    }

    func prepareForRouteChange() {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        readIndex = writeIndex
        availableFrames = 0
        minimumRenderFrames = 0
        primed = false
        lastL = 0
        lastR = 0
    }

    func pushPCM16(_ data: Data) {
        let frameCount = data.count / 4
        if frameCount <= 0 { return }

        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        if availableFrames + frameCount > maxFrames {
            let excess = (availableFrames + frameCount) - targetFrames
            let drop = min(excess, availableFrames)
            readIndex = (readIndex + drop) % capacityFrames
            availableFrames -= drop
        }

        let scale: Float = 1.0 / 32768.0
        data.withUnsafeBytes { rawBuf in
            for i in 0..<frameCount {
                if availableFrames >= capacityFrames {
                    readIndex = (readIndex + 1) % capacityFrames
                    availableFrames -= 1
                }
                let byteOffset = i * 4
                let l = Float(Int16(littleEndian: rawBuf.loadUnaligned(fromByteOffset: byteOffset, as: Int16.self))) * scale
                let r = Float(Int16(littleEndian: rawBuf.loadUnaligned(fromByteOffset: byteOffset + 2, as: Int16.self))) * scale
                let base = writeIndex * 2
                buffer[base] = l
                buffer[base + 1] = r
                writeIndex = (writeIndex + 1) % capacityFrames
                availableFrames += 1
            }
        }

        if !primed && availableFrames >= targetFrames {
            primed = true
            fadeInFrames = 240
        }
    }

    func pull(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, frameCount: Int) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        let oldTarget = targetFrames
        minimumRenderFrames = max(minimumRenderFrames, frameCount + 480)
        if targetFrames > oldTarget && availableFrames < targetFrames {
            primed = false
        }

        if !primed {
            var l = lastL
            var r = lastR
            for i in 0..<frameCount {
                l *= 0.92
                r *= 0.92
                left[i] = l
                right?[i] = r
            }
            lastL = abs(l) < 1e-5 ? 0 : l
            lastR = abs(r) < 1e-5 ? 0 : r
            return
        }

        let toRead = min(frameCount, availableFrames)
        for i in 0..<toRead {
            let base = readIndex * 2
            let gain = Float(240 - fadeInFrames) / 240
            let l = buffer[base] * gain
            let r = buffer[base + 1] * gain
            fadeInFrames = max(0, fadeInFrames - 1)
            left[i] = l
            right?[i] = r
            lastL = l
            lastR = r
            readIndex = (readIndex + 1) % capacityFrames
        }
        availableFrames -= toRead
        if toRead < frameCount {
            primed = false
            underruns += 1
            var l = lastL
            var r = lastR
            for i in toRead..<frameCount {
                l *= 0.92
                r *= 0.92
                left[i] = l
                right?[i] = r
            }
            lastL = abs(l) < 1e-5 ? 0 : l
            lastR = abs(r) < 1e-5 ? 0 : r
        }
    }
}

// MARK: - Dual Transport (USB usbmuxd TCP + LAN UDP) Audio Receiver

enum TransportMode: String {
    case waiting = "Đang chờ PC..."
    case usb = "USB Lightning"
    case lan = "Wi-Fi LAN"
}

final class AudioReceiver: NSObject, ObservableObject {
    static let port: UInt16 = 55123

    @Published var isRunning: Bool = false
    @Published var mode: TransportMode = .waiting
    @Published var localIP: String = "Đang lấy IP..."
    @Published var outputRoute: String = "Loa ngoài"
    @Published var bufferMs: Double = 0
    @Published var packetsPerSec: Int = 0
    @Published var droppedPackets: Int = 0
    @Published private(set) var latePackets = 0
    @Published private(set) var underruns = 0
    @Published private(set) var effectiveTargetMs = 0.0
    @Published private(set) var lastHandoffMs: Double?
    @Published private(set) var pcIdle = false
    @Published var targetBufferMs: Double = 20.0 {
        didSet { ringBuffer.setTargetMs(targetBufferMs) }
    }
    @Published var statusMessage: String = "Nhấn Bắt đầu để lắng nghe âm thanh từ PC"

    private let ringBuffer = AudioRingBuffer()
    private let netQueue = DispatchQueue(label: "com.nikvn2105.nikaudio.net", qos: .userInteractive)

    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var telemetryTimer: Timer?
    private var restartWork: DispatchWorkItem?
    private var lastEngineStart: TimeInterval = 0
    private var audioInterrupted = false
    private var lanKey: SymmetricKey?
    private var lanSessions: [Data: LANSession] = [:]

    private var udpListener: NWListener?
    private var tcpListener: NWListener?
    private var activeTCPConnections: [NWConnection] = []
    private var activeUDPConnections: [NWConnection] = []
    private weak var authenticatedAudioConnection: NWConnection?
    private var listenerSession: UUID?
    private var listenerWaitMessages: [String: String] = [:]
    private var listenerStatus: String {
        listenerWaitMessages.values.sorted().first ?? "Đang chờ kết nối USB hoặc Wi-Fi trên cổng \(Self.port)"
    }
    private var lastPacketTime: TimeInterval = 0
    private var lastTransportIsUSB: Bool = false
    private var lastContactTime: TimeInterval = 0
    private var lastContactIsUSB = false
    private var lateCounter = 0
    private var handoffMs: Double?
    private var packetCounter: Int = 0
    private var droppedCounter: Int = 0
    private var lastSeq: UInt32 = 0
    private var acceptedSequences: UInt64 = 0
    private var lastTelemetryTime: TimeInterval = 0
    private var hasSeq: Bool = false

    override init() {
        super.init()
        updateLocalIP()
        updateOutputRoute()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleMediaServicesReset(_:)),
            name: AVAudioSession.mediaServicesWereResetNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigChange(_:)),
            name: .AVAudioEngineConfigurationChange,
            object: nil
        )
    }

    deinit {
        restartWork?.cancel()
        telemetryTimer?.invalidate()
        engine?.stop()
        tcpListener?.cancel()
        udpListener?.cancel()
        for connection in activeTCPConnections { connection.cancel() }
        for connection in activeUDPConnections { connection.cancel() }
        NotificationCenter.default.removeObserver(self)
    }

    func toggle() {
        if isRunning { stop() } else { start() }
    }

    func start() {
        guard !isRunning else { return }
        let session = UUID()
        listenerSession = session
        audioInterrupted = false
        let key = try? LANPairing.key()
        ringBuffer.setTargetMs(targetBufferMs)
        ringBuffer.reset()

        netQueue.async { [weak self] in
            guard let self = self else { return }
            self.hasSeq = false
            self.droppedCounter = 0
            self.packetCounter = 0
            self.lastPacketTime = 0
            self.lastContactTime = 0
            self.lastTelemetryTime = 0
            self.lateCounter = 0
            self.handoffMs = nil
            self.lanKey = key.map { SymmetricKey(data: $0) }
            self.lanSessions.removeAll()
        }

        do {
            try setupAudioSessionAndEngine()
            try startListeners(session: session)
            isRunning = true
            droppedPackets = 0
            latePackets = 0
            underruns = 0
            lastHandoffMs = nil
            statusMessage = listenerStatus
            updateLocalIP()
            updateOutputRoute()
            startTelemetry()
        } catch {
            stop(message: "Lỗi khởi động: \(error.localizedDescription)")
        }
    }

    func stop(message: String = "Đã dừng") {
        let sessionWasOpen = listenerSession != nil
        listenerSession = nil
        restartWork?.cancel()
        restartWork = nil
        listenerWaitMessages.removeAll()
        telemetryTimer?.invalidate()
        telemetryTimer = nil

        netQueue.async { [weak self] in
            guard let self = self else { return }
            self.udpListener?.cancel()
            self.udpListener = nil
            self.tcpListener?.cancel()
            self.tcpListener = nil

            for conn in self.activeTCPConnections { conn.cancel() }
            self.activeTCPConnections.removeAll()
            for conn in self.activeUDPConnections { conn.cancel() }
            self.activeUDPConnections.removeAll()
            self.authenticatedAudioConnection = nil
            self.lanSessions.removeAll()
            self.lanKey = nil
            self.packetCounter = 0
            self.hasSeq = false
        }

        engine?.stop()
        engine = nil
        sourceNode = nil
        ringBuffer.reset()
        if sessionWasOpen {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }

        isRunning = false
        mode = .waiting
        packetsPerSec = 0
        bufferMs = 0
        pcIdle = false
        effectiveTargetMs = 0
        statusMessage = message
    }

    private func setupAudioSessionAndEngine() throws {
        engine?.stop()
        engine = nil
        sourceNode = nil

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setPreferredSampleRate(48000.0)
        try session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)

        let newEngine = AVAudioEngine()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48000.0, channels: 2) else {
            throw NSError(domain: "NiKAudio", code: -1, userInfo: [NSLocalizedDescriptionKey: "Không tạo được AudioFormat 48kHz"])
        }

        let rb = self.ringBuffer
        let src = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let count = Int(frameCount)
            if abl.count >= 2,
               let leftPtr = abl[0].mData?.assumingMemoryBound(to: Float.self),
               let rightPtr = abl[1].mData?.assumingMemoryBound(to: Float.self) {
                rb.pull(left: leftPtr, right: rightPtr, frameCount: count)
            } else if abl.count == 1,
                      let ptr = abl[0].mData?.assumingMemoryBound(to: Float.self) {
                rb.pull(left: ptr, right: nil, frameCount: count)
            }
            return noErr
        }

        newEngine.attach(src)
        newEngine.connect(src, to: newEngine.mainMixerNode, format: format)
        newEngine.prepare()
        try newEngine.start()

        lastEngineStart = ProcessInfo.processInfo.systemUptime
        self.engine = newEngine
        self.sourceNode = src
    }

    func pairingCode(renew: Bool = false) throws -> String {
        let key = try (renew ? LANPairing.renewKey() : LANPairing.key())
        netQueue.async { [weak self] in
            self?.lanKey = SymmetricKey(data: key)
            if renew { self?.lanSessions.removeAll() }
        }
        return key.map { String(format: "%02x", $0) }.joined()
    }

    private func scheduleEngineRestart(attempt: Int = 0) {
        guard let session = listenerSession, isRunning, !audioInterrupted else { return }
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.listenerSession == session, !self.audioInterrupted else { return }
            self.restartWork = nil
            self.engine?.stop()
            self.ringBuffer.prepareForRouteChange()
            do {
                try self.setupAudioSessionAndEngine()
                self.statusMessage = self.listenerStatus
                self.updateOutputRoute()
            } catch {
                self.statusMessage = "Lỗi khởi động lại âm thanh: \(error.localizedDescription)"
                if attempt < 2 { self.scheduleEngineRestart(attempt: attempt + 1) }
            }
        }
        restartWork = work
        let delay = attempt == 0 ? 180 : 500 * attempt
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay), execute: work)
    }

    private func startListeners(session: UUID) throws {
        guard let port = NWEndpoint.Port(rawValue: Self.port) else { return }

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let tcpParams = NWParameters(tls: nil, tcp: tcpOptions)
        // The phone-side usbmux service connects to the device loopback interface.
        tcpParams.requiredInterfaceType = .loopback
        tcpParams.allowLocalEndpointReuse = true
        let tcp = try NWListener(using: tcpParams, on: port)
        tcp.stateUpdateHandler = listenerStateHandler(for: "USB TCP", session: session)
        tcp.newConnectionHandler = { [weak self] conn in
            self?.handleTCPConnection(conn)
        }

        let udpParams = NWParameters.udp
        udpParams.allowLocalEndpointReuse = true
        udpParams.serviceClass = .interactiveVoice
        let udp = try NWListener(using: udpParams, on: port)
        udp.stateUpdateHandler = listenerStateHandler(for: "Wi-Fi UDP", session: session)
        udp.newConnectionHandler = { [weak self] conn in
            self?.handleUDPConnection(conn)
        }

        netQueue.async { [weak self] in
            guard let self = self else { return }
            self.tcpListener = tcp
            self.udpListener = udp
            tcp.start(queue: self.netQueue)
            udp.start(queue: self.netQueue)
        }
    }

    private func listenerStateHandler(for transport: String, session: UUID) -> (NWListener.State) -> Void {
        return { [weak self] state in
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.listenerSession == session else { return }
                switch state {
                case let .failed(error):
                    self.stop(message: "Lỗi mở cổng \(Self.port) (\(transport)): \(error.localizedDescription)")
                case let .waiting(error):
                    self.listenerWaitMessages[transport] = "Đang chờ mở cổng \(Self.port) (\(transport)): \(error.localizedDescription)"
                    self.statusMessage = self.listenerStatus
                case .ready:
                    self.listenerWaitMessages.removeValue(forKey: transport)
                    self.statusMessage = self.listenerStatus
                default:
                    break
                }
            }
        }
    }

    private func handleTCPConnection(_ conn: NWConnection) {
        activeTCPConnections.append(conn)
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self = self, let conn = conn else { return }
            switch state {
            case .failed, .cancelled:
                self.activeTCPConnections.removeAll { $0 === conn }
            default:
                break
            }
        }
        conn.start(queue: netQueue)
        receiveTCPChunk(conn: conn, stream: TCPStream())
    }

    private final class TCPStream {
        var buffer = Data()
    }

    private func receiveTCPChunk(conn: NWConnection, stream: TCPStream) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                stream.buffer.append(data)
                self.parseTCPStream(&stream.buffer)
            }
            if isComplete || error != nil {
                conn.cancel()
                self.activeTCPConnections.removeAll { $0 === conn }
                return
            }
            self.receiveTCPChunk(conn: conn, stream: stream)
        }
    }

    private func parseTCPStream(_ buffer: inout Data) {
        while buffer.count >= 12 {
            if buffer[buffer.startIndex] == 0x4E,
               buffer[buffer.startIndex + 1] == 0x49,
               buffer[buffer.startIndex + 2] == 0x4B,
               buffer[buffer.startIndex + 3] == 0x41 {
                let seq = buffer.readUInt32LE(at: 4)
                let payloadLen = Int(buffer.readUInt16LE(at: 8))
                let flags = buffer.readUInt16LE(at: 10)
                if !isValidPacket(payloadLen: payloadLen, flags: flags) {
                    buffer.removeFirst(4)
                    continue
                }
                let totalLen = 12 + payloadLen
                if buffer.count < totalLen { return }
                let payload = buffer.subdata(in: (buffer.startIndex + 12)..<(buffer.startIndex + totalLen))
                buffer.removeFirst(totalLen)
                self.ingestPacket(seq: seq, payload: payload, isUSB: true)
            } else {
                buffer.removeFirst(1)
            }
        }
    }

    private func handleUDPConnection(_ conn: NWConnection) {
        if activeUDPConnections.count >= 16,
           let index = activeUDPConnections.firstIndex(where: { $0 !== authenticatedAudioConnection }) {
            activeUDPConnections.remove(at: index).cancel()
        }
        activeUDPConnections.append(conn)
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self = self, let conn = conn else { return }
            switch state {
            case .failed, .cancelled:
                self.activeUDPConnections.removeAll { $0 === conn }
            default:
                break
            }
        }
        conn.start(queue: netQueue)
        receiveUDPMessage(conn: conn)
    }

    private func receiveUDPMessage(conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self = self else { return }
            if let data = data { self.handleLANDatagram(data, connection: conn) }
            if error == nil {
                self.receiveUDPMessage(conn: conn)
            } else {
                conn.cancel()
                self.activeUDPConnections.removeAll { $0 === conn }
            }
        }
    }

    private func isValidPacket(payloadLen: Int, flags: UInt16) -> Bool {
        (flags == 0 && payloadLen == 480) || (flags == 1 && payloadLen == 0)
    }

    private func handleLANDatagram(_ data: Data, connection: NWConnection) {
        guard let key = lanKey else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if data.count == 4 + LANPairing.nonceSize + LANPairing.tagSize,
           data.prefix(4) == Data("NIKD".utf8) {
            let signed = data.dropLast(LANPairing.tagSize)
            let tag = data.suffix(LANPairing.tagSize)
            guard HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: signed, using: key) else { return }
            let challenge = Data(signed.dropFirst(4))
            lanSessions = lanSessions.filter { now < $0.value.expiresAt }
            let session: LANSession
            if let existing = lanSessions.values.first(where: { $0.challenge == challenge }) {
                session = existing
            } else {
                guard lanSessions.count < 12,
                      let nonce = LANPairing.randomBytes(count: LANPairing.nonceSize) else { return }
                let material = HMAC<SHA256>.authenticationCode(for: nonce, using: key)
                session = LANSession(challenge: challenge, nonce: nonce, expiresAt: now + 25,
                                     key: SymmetricKey(data: Data(material)),
                                     lastAudioSeq: nil, lastHeartbeatSeq: nil)
                lanSessions[nonce] = session
            }
            var response = Data("NIKR".utf8)
            response.append(challenge)
            response.append(session.nonce)
            response.append(contentsOf: HMAC<SHA256>.authenticationCode(for: response, using: key))
            connection.send(content: response, completion: .idempotent)
            return
        }

        let prefixSize = 12 + LANPairing.nonceSize
        guard data.count >= prefixSize + LANPairing.cipherTagSize,
              data.prefix(4) == Data("NIKA".utf8) else { return }
        let payloadLen = Int(data.readUInt16LE(at: 8))
        let flags = data.readUInt16LE(at: 10)
        guard isValidPacket(payloadLen: payloadLen, flags: flags),
              data.count == prefixSize + payloadLen + LANPairing.cipherTagSize else { return }
        let prefix = data.prefix(prefixSize)
        let nonce = Data(prefix.suffix(LANPairing.nonceSize))
        guard var session = lanSessions[nonce], now < session.expiresAt else { return }
        let seq = data.readUInt32LE(at: 4)
        guard let payload = session.decrypt(data, prefixSize: prefixSize, payloadLength: payloadLen,
                                            flags: flags) else { return }
        guard session.accept(seq: seq, heartbeat: flags == 1) else {
            if flags == 0 { recordLatePacket(seq: seq) }
            return
        }
        lanSessions[nonce] = session
        authenticatedAudioConnection = connection
        ingestPacket(seq: seq, payload: payload, isUSB: false)
    }

    private func recordLatePacket(seq: UInt32) {
        guard hasSeq else { return }
        let behind = Int64(Int32(bitPattern: lastSeq &- seq))
        if behind > 0 && (behind >= 64 || (acceptedSequences & (1 << behind)) == 0) {
            lateCounter += 1
        }
    }

    private func ingestPacket(seq: UInt32, payload: Data, isUSB: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if payload.isEmpty {
            if now - lastPacketTime > 0.4 && (isUSB || !lastContactIsUSB || now - lastContactTime > 0.7) {
                lastContactTime = now
                lastContactIsUSB = isUSB
            }
            return
        }
        let gap = now - lastPacketTime
        if hasSeq && gap <= 1 {
            let delta = Int32(bitPattern: seq &- lastSeq)
            if delta <= 0 {
                recordLatePacket(seq: seq)
                return
            }
            acceptedSequences = delta < 64 ? (acceptedSequences << delta) | 1 : 1
            if delta < 1000 { droppedCounter += Int(delta - 1) }
            if isUSB != lastTransportIsUSB { handoffMs = gap * 1000 }
        } else {
            acceptedSequences = 1
        }

        hasSeq = true
        lastSeq = seq
        lastTransportIsUSB = isUSB
        lastPacketTime = now
        lastContactTime = now
        lastContactIsUSB = isUSB
        packetCounter += 1
        ringBuffer.pushPCM16(payload)
    }

    private func startTelemetry() {
        telemetryTimer?.invalidate()
        telemetryTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self, let session = self.listenerSession else { return }
            self.netQueue.async {
                let now = ProcessInfo.processInfo.systemUptime
                let currentMode: TransportMode
                if self.lastContactTime > 0 && now - self.lastContactTime < 1.0 {
                    currentMode = self.lastContactIsUSB ? .usb : .lan
                } else {
                    currentMode = .waiting
                }
                let elapsed = self.lastTelemetryTime > 0 ? max(0.1, now - self.lastTelemetryTime) : 0.5
                self.lastTelemetryTime = now
                let pps = Int(Double(self.packetCounter) / elapsed)
                self.packetCounter = 0
                self.ringBuffer.updateAdaptiveTarget(activeLAN: currentMode == .lan && pps > 200,
                                                     elapsed: min(elapsed, 1))
                let dropped = self.droppedCounter
                let diagnostics = self.ringBuffer.diagnostics()
                let late = self.lateCounter
                let handoff = self.handoffMs
                let idle = currentMode != .waiting && now - self.lastPacketTime > 0.5

                DispatchQueue.main.async {
                    guard self.listenerSession == session else { return }
                    self.mode = currentMode
                    self.packetsPerSec = pps
                    self.droppedPackets = dropped
                    self.bufferMs = diagnostics.bufferMs
                    self.effectiveTargetMs = diagnostics.targetMs
                    self.underruns = diagnostics.underruns
                    self.latePackets = late
                    self.lastHandoffMs = handoff
                    self.pcIdle = idle
                }
            }
        }
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        updateOutputRoute()
        guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
              reason == .newDeviceAvailable || reason == .oldDeviceUnavailable else { return }
        DispatchQueue.main.async { [weak self] in self?.scheduleEngineRestart() }
    }

    @objc private func handleEngineConfigChange(_ notification: Notification) {
        guard let changedEngine = notification.object as? AVAudioEngine else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.engine === changedEngine,
                  !changedEngine.isRunning ||
                  ProcessInfo.processInfo.systemUptime - self.lastEngineStart > 0.5 else { return }
            self.scheduleEngineRestart()
        }
    }

    @objc private func handleMediaServicesReset(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.audioInterrupted = false
            self?.scheduleEngineRestart()
        }
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeVal = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeVal) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isRunning else { return }
            self.audioInterrupted = type == .began
            if self.audioInterrupted {
                self.restartWork?.cancel()
                self.restartWork = nil
            } else {
                self.scheduleEngineRestart()
            }
        }
    }

    func updateOutputRoute() {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let name = outputs.first?.portName ?? "Loa ngoài"
        DispatchQueue.main.async { self.outputRoute = name }
    }

    func updateLocalIP() {
        var address = "Không có Wi-Fi"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr {
            var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
            while let current = ptr {
                let flags = Int32(current.pointee.ifa_flags)
                ptr = current.pointee.ifa_next
                guard let socketAddress = current.pointee.ifa_addr else { continue }
                let addr = socketAddress.pointee
                if (flags & (IFF_UP | IFF_RUNNING | IFF_LOOPBACK)) == (IFF_UP | IFF_RUNNING),
                   addr.sa_family == UInt8(AF_INET) {
                    let name = String(cString: current.pointee.ifa_name)
                    if name == "en0" {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(
                            socketAddress,
                            socklen_t(addr.sa_len),
                            &hostname,
                            socklen_t(hostname.count),
                            nil,
                            0,
                            NI_NUMERICHOST
                        )
                        address = String(cString: hostname)
                        break
                    }
                }
            }
            freeifaddrs(ifaddr)
        }
        DispatchQueue.main.async { self.localIP = address }
    }
}

private extension Data {
    func readUInt32LE(at offset: Int) -> UInt32 {
        let idx = startIndex + offset
        let b0 = UInt32(self[idx])
        let b1 = UInt32(self[idx + 1]) << 8
        let b2 = UInt32(self[idx + 2]) << 16
        let b3 = UInt32(self[idx + 3]) << 24
        return b0 | b1 | b2 | b3
    }

    func readUInt16LE(at offset: Int) -> UInt16 {
        let idx = startIndex + offset
        let b0 = UInt16(self[idx])
        let b1 = UInt16(self[idx + 1]) << 8
        return b0 | b1
    }
}

@main
struct NiKAudioApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView()
                    .tabItem { Label("Âm thanh", systemImage: "waveform") }
                FileTransferView()
                    .tabItem { Label("Tệp", systemImage: "folder") }
                ScreenProbeView()
                    .tabItem { Label("Màn hình", systemImage: "iphone.gen3") }
            }
            .tint(GlassTheme.mint)
            .preferredColorScheme(.dark)
        }
    }
}
