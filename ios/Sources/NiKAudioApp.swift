import SwiftUI
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

    private var targetFrames: Int = 960  // 20ms @ 48kHz
    private var maxFrames: Int = 2880    // 60ms ceiling before trimming drift
    private var primed: Bool = false

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
        targetFrames = Int((clamped / 1000.0) * 48000.0)
        maxFrames = max(targetFrames * 2 + 480, 2400)
        os_unfair_lock_unlock(lock)
    }

    func reset() {
        os_unfair_lock_lock(lock)
        readIndex = 0
        writeIndex = 0
        availableFrames = 0
        primed = false
        lastL = 0
        lastR = 0
        os_unfair_lock_unlock(lock)
    }

    func bufferedMs() -> Double {
        os_unfair_lock_lock(lock)
        let frames = availableFrames
        os_unfair_lock_unlock(lock)
        return (Double(frames) / 48000.0) * 1000.0
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
            guard let ptr = rawBuf.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<frameCount {
                if availableFrames >= capacityFrames {
                    readIndex = (readIndex + 1) % capacityFrames
                    availableFrames -= 1
                }
                let l = Float(Int16(littleEndian: ptr[i * 2])) * scale
                let r = Float(Int16(littleEndian: ptr[i * 2 + 1])) * scale
                let base = writeIndex * 2
                buffer[base] = l
                buffer[base + 1] = r
                writeIndex = (writeIndex + 1) % capacityFrames
                availableFrames += 1
            }
        }

        if !primed && availableFrames >= targetFrames {
            primed = true
        }
    }

    func pull(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>?, frameCount: Int) {
        os_unfair_lock_lock(lock)

        if !primed || availableFrames == 0 {
            os_unfair_lock_unlock(lock)
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
            let l = buffer[base]
            let r = buffer[base + 1]
            left[i] = l
            right?[i] = r
            lastL = l
            lastR = r
            readIndex = (readIndex + 1) % capacityFrames
        }
        availableFrames -= toRead
        if availableFrames == 0 {
            primed = false
        }
        os_unfair_lock_unlock(lock)

        if toRead < frameCount {
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
    @Published var targetBufferMs: Double = 20.0 {
        didSet { ringBuffer.setTargetMs(targetBufferMs) }
    }
    @Published var statusMessage: String = "Nhấn Bắt đầu để lắng nghe âm thanh từ PC"

    private let ringBuffer = AudioRingBuffer()
    private let netQueue = DispatchQueue(label: "com.nikvn2105.nikaudio.net", qos: .userInteractive)

    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private var telemetryTimer: Timer?

    private var udpListener: NWListener?
    private var tcpListener: NWListener?
    private var activeTCPConnections: [NWConnection] = []
    private var activeUDPConnections: [NWConnection] = []
    private var lastUSBTime: CFAbsoluteTime = 0
    private var lastLANTime: CFAbsoluteTime = 0
    private var lastPacketTime: CFAbsoluteTime = 0
    private var lastTransportIsUSB: Bool = false
    private var packetCounter: Int = 0
    private var droppedCounter: Int = 0
    private var lastSeq: UInt32 = 0
    private var hasSeq: Bool = false

    override init() {
        super.init()
        updateLocalIP()
        updateOutputRoute()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
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
            selector: #selector(handleEngineConfigChange),
            name: .AVAudioEngineConfigurationChange,
            object: nil
        )
    }

    deinit {
        stop()
        NotificationCenter.default.removeObserver(self)
    }

    func toggle() {
        if isRunning { stop() } else { start() }
    }

    func start() {
        guard !isRunning else { return }
        ringBuffer.setTargetMs(targetBufferMs)
        ringBuffer.reset()

        netQueue.async { [weak self] in
            guard let self = self else { return }
            self.hasSeq = false
            self.droppedCounter = 0
            self.packetCounter = 0
            self.lastUSBTime = 0
            self.lastLANTime = 0
            self.lastPacketTime = 0
        }

        do {
            try setupAudioSessionAndEngine()
            try startListeners()
            isRunning = true
            droppedPackets = 0
            statusMessage = "Đang chờ kết nối USB hoặc Wi-Fi trên cổng \(Self.port)"
            updateLocalIP()
            updateOutputRoute()
            startTelemetry()
        } catch {
            statusMessage = "Lỗi khởi động: \(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
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
            self.packetCounter = 0
            self.hasSeq = false
        }

        engine?.stop()
        engine = nil
        sourceNode = nil
        ringBuffer.reset()

        DispatchQueue.main.async {
            self.isRunning = false
            self.mode = .waiting
            self.packetsPerSec = 0
            self.bufferMs = 0
            self.statusMessage = "Đã dừng"
        }
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

        self.engine = newEngine
        self.sourceNode = src
    }

    private func restartAudioEngineIfNeeded() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isRunning else { return }
            do {
                try self.setupAudioSessionAndEngine()
                self.updateOutputRoute()
            } catch {
                self.statusMessage = "Lỗi khởi động lại âm thanh: \(error.localizedDescription)"
            }
        }
    }

    private func startListeners() throws {
        guard let port = NWEndpoint.Port(rawValue: Self.port) else { return }

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let tcpParams = NWParameters(tls: nil, tcp: tcpOptions)
        tcpParams.allowLocalEndpointReuse = true
        let tcp = try NWListener(using: tcpParams, on: port)
        tcp.newConnectionHandler = { [weak self] conn in
            self?.handleTCPConnection(conn)
        }

        let udpParams = NWParameters.udp
        udpParams.allowLocalEndpointReuse = true
        udpParams.serviceClass = .interactiveVoice
        let udp = try NWListener(using: udpParams, on: port)
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

    private func handleTCPConnection(_ conn: NWConnection) {
        activeTCPConnections.append(conn)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .failed, .cancelled:
                self.activeTCPConnections.removeAll { $0 === conn }
            default:
                break
            }
        }
        conn.start(queue: netQueue)
        receiveTCPChunk(conn: conn, accumulator: Data())
    }

    private func receiveTCPChunk(conn: NWConnection, accumulator: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            var acc = accumulator
            if let data = data, !data.isEmpty {
                acc.append(data)
                self.parseTCPStream(&acc)
            }
            if isComplete || error != nil {
                conn.cancel()
                self.activeTCPConnections.removeAll { $0 === conn }
                return
            }
            self.receiveTCPChunk(conn: conn, accumulator: acc)
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
                if payloadLen == 0 || payloadLen > 8192 {
                    buffer.removeFirst(4)
                    continue
                }
                let totalLen = 12 + payloadLen
                if buffer.count < totalLen { return }
                let payload = buffer.subdata(in: (buffer.startIndex + 12)..<(buffer.startIndex + totalLen))
                buffer.removeFirst(totalLen)
                self.ingestAudioFrame(seq: seq, payload: payload, isUSB: true)
            } else {
                buffer.removeFirst(1)
            }
        }
    }

    private func handleUDPConnection(_ conn: NWConnection) {
        if activeUDPConnections.count > 8 {
            activeUDPConnections.first?.cancel()
            activeUDPConnections.removeFirst()
        }
        activeUDPConnections.append(conn)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
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
            if let data = data, data.count >= 4 {
                if data[data.startIndex] == 0x4E,
                   data[data.startIndex + 1] == 0x49,
                   data[data.startIndex + 2] == 0x4B,
                   data[data.startIndex + 3] == 0x44 {
                    conn.send(content: Data("NIKR".utf8), completion: .idempotent)
                } else if data.count >= 12,
                          data[data.startIndex] == 0x4E,
                          data[data.startIndex + 1] == 0x49,
                          data[data.startIndex + 2] == 0x4B,
                          data[data.startIndex + 3] == 0x41 {
                    let seq = data.readUInt32LE(at: 4)
                    let payloadLen = Int(data.readUInt16LE(at: 8))
                    if payloadLen > 0 && 12 + payloadLen <= data.count {
                        let payload = data.subdata(in: (data.startIndex + 12)..<(data.startIndex + 12 + payloadLen))
                        self.ingestAudioFrame(seq: seq, payload: payload, isUSB: false)
                    }
                }
            }
            if error == nil {
                self.receiveUDPMessage(conn: conn)
            } else {
                conn.cancel()
                self.activeUDPConnections.removeAll { $0 === conn }
            }
        }
    }

    private func ingestAudioFrame(seq: UInt32, payload: Data, isUSB: Bool) {
        let now = CFAbsoluteTimeGetCurrent()
        if isUSB {
            lastUSBTime = now
        } else {
            if now - lastUSBTime < 0.5 { return }
            lastLANTime = now
        }

        if !hasSeq || isUSB != lastTransportIsUSB || (now - lastPacketTime) > 1.0 {
            lastSeq = seq
            hasSeq = true
            lastTransportIsUSB = isUSB
            lastPacketTime = now
            packetCounter += 1
            ringBuffer.pushPCM16(payload)
            return
        }

        let delta = Int32(bitPattern: seq &- lastSeq)
        if !isUSB && delta <= 0 {
            return
        }
        if delta > 1 && delta < 1000 {
            droppedCounter += Int(delta - 1)
        }

        lastSeq = seq
        lastTransportIsUSB = isUSB
        lastPacketTime = now
        packetCounter += 1
        ringBuffer.pushPCM16(payload)
    }

    private func startTelemetry() {
        telemetryTimer?.invalidate()
        telemetryTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.netQueue.async {
                let now = CFAbsoluteTimeGetCurrent()
                let currentMode: TransportMode
                if now - self.lastUSBTime < 1.0 {
                    currentMode = .usb
                } else if now - self.lastLANTime < 1.0 {
                    currentMode = .lan
                } else {
                    currentMode = .waiting
                }
                let pps = self.packetCounter * 2
                self.packetCounter = 0
                let dropped = self.droppedCounter
                let bufMs = self.ringBuffer.bufferedMs()

                DispatchQueue.main.async {
                    self.mode = currentMode
                    self.packetsPerSec = pps
                    self.droppedPackets = dropped
                    self.bufferMs = bufMs
                }
            }
        }
    }

    @objc private func handleRouteChange() {
        updateOutputRoute()
    }

    @objc private func handleEngineConfigChange() {
        restartAudioEngineIfNeeded()
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeVal = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeVal) else { return }
        if type == .ended {
            restartAudioEngineIfNeeded()
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
                let addr = current.pointee.ifa_addr.pointee
                if (flags & (IFF_UP | IFF_RUNNING | IFF_LOOPBACK)) == (IFF_UP | IFF_RUNNING),
                   addr.sa_family == UInt8(AF_INET) {
                    let name = String(cString: current.pointee.ifa_name)
                    if name == "en0" {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(
                            current.pointee.ifa_addr,
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
                ptr = current.pointee.ifa_next
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
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}

struct ContentView: View {
    @StateObject private var receiver = AudioReceiver()

    var statusColor: Color {
        switch receiver.mode {
        case .usb: return .green
        case .lan: return .cyan
        case .waiting: return receiver.isRunning ? .orange : .gray
        }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 18) {
                    VStack(spacing: 10) {
                        HStack {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 12, height: 12)
                            Text(receiver.isRunning ? receiver.mode.rawValue : "Chưa bật")
                                .font(.headline)
                            Spacer()
                            Text("Port \(AudioReceiver.port)")
                                .font(.caption.monospaced())
                                .foregroundColor(.secondary)
                        }
                        Divider()
                        infoRow(title: "IP Wi-Fi iPhone", value: receiver.localIP)
                        infoRow(title: "Đầu ra âm thanh (A2DP)", value: receiver.outputRoute)
                        infoRow(title: "Bộ đệm hiện tại", value: String(format: "%.1f ms", receiver.bufferMs))
                        infoRow(title: "Tốc độ gói", value: "\(receiver.packetsPerSec) pkt/s")
                        infoRow(title: "Gói rớt", value: "\(receiver.droppedPackets)")
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(16)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Mức đệm mục tiêu (Jitter Buffer)")
                                .font(.subheadline.bold())
                            Spacer()
                            Text("\(Int(receiver.targetBufferMs)) ms")
                                .font(.subheadline.monospaced())
                                .foregroundColor(.cyan)
                        }
                        Slider(value: $receiver.targetBufferMs, in: 10...60, step: 1)
                        Text("20ms là mức ổn định mặc định cho WASAPI + TWS; kéo xuống 12–15ms nếu mạng thật sạch.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(16)

                    Button(action: { receiver.toggle() }) {
                        HStack {
                            Image(systemName: receiver.isRunning ? "stop.fill" : "play.fill")
                            Text(receiver.isRunning ? "Dừng nhận âm thanh" : "Bắt đầu nhận âm thanh")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(receiver.isRunning ? Color.red : Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(14)
                    }

                    Text(receiver.statusMessage)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
            .navigationTitle("NiKAudio")
        }
    }

    private func infoRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.monospaced())
                .foregroundColor(.primary)
        }
    }
}
