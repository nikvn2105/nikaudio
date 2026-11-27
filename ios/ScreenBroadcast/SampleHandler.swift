import CoreImage
import CoreMedia
import ImageIO
import Network
import ReplayKit
import VideoToolbox

final class SampleHandler: RPBroadcastSampleHandler {
    private var storage: UserDefaults?
    private var transport: Task<Void, Never>?
    private var frames: AsyncStream<Data>.Continuation?
    private var encoder: VTCompressionSession?
    private var encoderSize = CGSize.zero
    private var pool: CVPixelBufferPool?
    private let renderer = CIContext(options: [.cacheIntermediates: false])
    private var lastFrame = CMTime.invalid
    private let frameLock = NSLock()
    private var sequence: UInt32 = 0
    private var inFlight = 0

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard let storage = ScreenProbe.storage,
              let data = storage.data(forKey: ScreenProbe.configKey),
              let destination = try? JSONDecoder().decode(ScreenProbe.Destination.self, from: data),
              destination.key.count == 32 else {
            finishBroadcastWithError(NSError(domain: "NiKAudio.ScreenBroadcast", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Mở NiKAudio, chuẩn bị PC nhận màn hình và kiểm tra quyền App Group."
            ]))
            return
        }
        self.storage = storage
        let endpoint: NWEndpoint
        if let service = destination.service {
            endpoint = .service(name: service, type: "_nikscreen._tcp", domain: "local.", interface: nil)
        } else if let address = IPv4Address(destination.address) {
            endpoint = .hostPort(host: .ipv4(address), port: NWEndpoint.Port(rawValue: 55125)!)
        } else {
            finishBroadcastWithError(NSError(domain: "NiKAudio.ScreenBroadcast", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Địa chỉ PC lưu trên iPhone không hợp lệ."
            ]))
            return
        }

        let stream = AsyncStream<Data>(bufferingPolicy: .bufferingNewest(2)) { continuation in
            self.frames = continuation
        }
        storage.set(ScreenProbe.State.started.rawValue, forKey: ScreenProbe.stateKey)
        transport = Task.detached(priority: .userInitiated) {
            var channel: FileChannel?
            defer { channel?.close() }
            var lastSequence: UInt32?
            for await packet in stream {
                if Task.isCancelled { break }
                let keyframe = packet.first == 9
                let sequence: UInt32 = packet.fileLE(at: 1)
                if let last = lastSequence, sequence != last &+ 1 {
                    channel?.close()
                    channel = nil
                }
                lastSequence = sequence
                do {
                    if channel == nil {
                        guard keyframe else { continue }
                        let next = FileChannel(endpoint: endpoint, pairingKey: destination.key, magic: "NIKS",
                                               timeout: 3, background: false)
                        channel = next
                        try await next.authenticate()
                    }
                    try await channel?.send(packet)
                    if keyframe { storage.set(ScreenProbe.State.video.rawValue, forKey: ScreenProbe.stateKey) }
                } catch {
                    channel?.close()
                    channel = nil
                    storage.set(ScreenProbe.State.reconnecting.rawValue, forKey: ScreenProbe.stateKey)
                }
            }
        }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video, frames != nil,
              let source = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard timestamp.isNumeric else { return }
        if lastFrame.isValid && CMTimeCompare(CMTimeSubtract(timestamp, lastFrame), CMTime(value: 1, timescale: 32)) < 0 {
            return
        }

        frameLock.lock()
        let busy = inFlight >= 2
        frameLock.unlock()
        guard !busy else { return }

        let orientation = (CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                                           attachmentModeOut: nil) as? NSNumber)?.int32Value ?? 1
        let image = CIImage(cvPixelBuffer: source).oriented(forExifOrientation: orientation)
        let extent = image.extent
        guard extent.width > 0 && extent.height > 0 else { return }
        let factor = extent.height > extent.width
            ? min(720 / extent.width, 1280 / extent.height)
            : min(1280 / extent.width, 720 / extent.height)
        let size = CGSize(width: max(2, Int(extent.width * factor) / 2 * 2),
                          height: max(2, Int(extent.height * factor) / 2 * 2))
        if size != encoderSize || encoder == nil {
            guard configure(size) else { return }
        }

        guard let encoder = encoder, let pool = pool else { return }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output) == kCVReturnSuccess,
              let output = output else { return }
        let prepared = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: size.width / extent.width, y: size.height / extent.height))
        renderer.render(prepared, to: output, bounds: CGRect(origin: .zero, size: size),
                        colorSpace: CGColorSpaceCreateDeviceRGB())

        frameLock.lock()
        inFlight += 1
        frameLock.unlock()
        let result = VTCompressionSessionEncodeFrame(encoder, imageBuffer: output,
            presentationTimeStamp: timestamp, duration: CMTime(value: 1, timescale: 30),
            frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil)
        if result != noErr { encoded(nil) }
        lastFrame = timestamp
    }

    private func configure(_ size: CGSize) -> Bool {
        closeEncoder()
        var session: VTCompressionSession?
        let width = Int32(size.width), height = Int32(size.height)
        let attributes = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: Int(width),
            kCVPixelBufferHeightKey: Int(height)
        ] as CFDictionary
        let result = VTCompressionSessionCreate(allocator: nil, width: width, height: height,
            codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
            imageBufferAttributes: attributes, compressedDataAllocator: nil,
            outputCallback: { ref, _, status, _, sample in
                guard let ref = ref else { return }
                let handler = Unmanaged<SampleHandler>.fromOpaque(ref).takeUnretainedValue()
                handler.encoded(status == noErr ? sample : nil)
            }, refcon: Unmanaged.passUnretained(self).toOpaque(), compressionSessionOut: &session)
        guard result == noErr, let session = session else { return false }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 2_500_000 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: [312_500, 1] as CFArray)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 30 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1 as CFNumber)
        guard VTCompressionSessionPrepareToEncodeFrames(session) == noErr else {
            VTCompressionSessionInvalidate(session)
            return false
        }
        var pixelPool: CVPixelBufferPool?
        let poolResult = CVPixelBufferPoolCreate(nil, nil, attributes, &pixelPool)
        guard poolResult == kCVReturnSuccess, let pixelPool = pixelPool else {
            VTCompressionSessionInvalidate(session)
            return false
        }
        self.pool = pixelPool
        encoder = session
        encoderSize = size
        return true
    }

    private func encoded(_ sample: CMSampleBuffer?) {
        frameLock.lock()
        defer { inFlight -= 1; frameLock.unlock() }
        let seq = sequence
        sequence &+= 1
        guard let sample = sample, let format = CMSampleBufferGetFormatDescription(sample),
              let buffer = CMSampleBufferGetDataBuffer(sample) else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let key = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true

        var packet = Data([key ? 9 : 10]) + Data(fileLE: seq)
        let startCode = Data([0, 0, 0, 1])
        if key {
            for index in 0..<2 {
                var bytes: UnsafePointer<UInt8>?
                var count = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                    parameterSetPointerOut: &bytes, parameterSetSizeOut: &count,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let bytes = bytes else { return }
                packet.append(startCode)
                packet.append(bytes, count: count)
            }
        }

        let total = CMBlockBufferGetDataLength(buffer)
        guard total > 4, total < 256 * 1024 else { return }
        var avcc = Data(count: total)
        let result = avcc.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: total, destination: raw.baseAddress!)
        }
        guard result == kCMBlockBufferNoErr else { return }
        var offset = 0
        while offset + 4 <= total {
            let length = avcc[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            offset += 4
            guard length > 0 && length <= total - offset else { return }
            packet.append(startCode)
            packet.append(avcc[offset..<offset + length])
            offset += length
        }
        guard offset == total && packet.count <= 256 * 1024 + 1 else { return }
        frames?.yield(packet)
    }

    private func closeEncoder() {
        if let encoder = encoder {
            VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(encoder)
        }
        encoder = nil
        pool = nil
    }

    override func broadcastFinished() {
        closeEncoder()
        frames?.finish()
        frames = nil
        transport?.cancel()
        transport = nil
        storage?.set(ScreenProbe.State.stopped.rawValue, forKey: ScreenProbe.stateKey)
    }
}
