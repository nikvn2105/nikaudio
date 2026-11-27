import Foundation
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
    private var pendingUnderrun = false
    private var senderIdle = true
    private var lastAudioWasUSB = false
    private var filteredFillError = 0.0
    private var fractionalOffset = 0.0
    private var trimmedFrames = 0
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
        os_unfair_lock_unlock(lock)
    }

    func reset() {
        os_unfair_lock_lock(lock)
        readIndex = 0
        writeIndex = 0
        availableFrames = 0
        minimumRenderFrames = 0
        underruns = 0
        pendingUnderrun = false
        filteredFillError = 0
        fractionalOffset = 0
        trimmedFrames = 0
        senderIdle = true
        lastAudioWasUSB = false
        adaptiveFrames = 0
        stableTime = 0
        fadeInFrames = 0
        primed = false
        lastL = 0
        lastR = 0
        os_unfair_lock_unlock(lock)
    }

    func diagnostics() -> (bufferMs: Double, targetMs: Double, underruns: Int, trimmedFrames: Int) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return (Double(availableFrames) / 48, Double(targetFrames) / 48, underruns, trimmedFrames)
    }

    func updateAdaptiveTarget(activeLAN: Bool, elapsed: TimeInterval) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        guard activeLAN, !senderIdle, primed, !pendingUnderrun else {
            stableTime = 0
            return
        }
        stableTime += elapsed
        if stableTime >= 20 {
            adaptiveFrames = max(0, adaptiveFrames - 96)
            stableTime = 0
        }
    }

    func markSenderIdle() {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        senderIdle = true
        pendingUnderrun = false
        filteredFillError = 0
        fractionalOffset = 0
        stableTime = 0
    }

    func prepareForRouteChange() {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        readIndex = writeIndex
        availableFrames = 0
        minimumRenderFrames = 0
        pendingUnderrun = false
        filteredFillError = 0
        fractionalOffset = 0
        primed = false
        lastL = 0
        lastR = 0
    }

    func pushPCM16(_ data: Data, isUSB: Bool, captureResumed: Bool = false) {
        let frameCount = data.count / 4
        if frameCount <= 0 { return }

        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        if pendingUnderrun {
            if !captureResumed {
                underruns += 1
                if !lastAudioWasUSB && !isUSB {
                    adaptiveFrames = min(1440, adaptiveFrames + 240)
                }
            }
            pendingUnderrun = false
            stableTime = 0
        }
        if isUSB && !lastAudioWasUSB {
            adaptiveFrames = 0
            stableTime = 0
        }
        senderIdle = false
        lastAudioWasUSB = isUSB

        if availableFrames + frameCount > maxFrames {
            let excess = (availableFrames + frameCount) - targetFrames
            let drop = min(excess, availableFrames)
            readIndex = (readIndex + drop) % capacityFrames
            availableFrames -= drop
            trimmedFrames += drop
            fractionalOffset = 0
            filteredFillError = 0
            fadeInFrames = 240
        }

        let scale: Float = 1.0 / 32768.0
        data.withUnsafeBytes { rawBuf in
            for i in 0..<frameCount {
                if availableFrames >= capacityFrames {
                    readIndex = (readIndex + 1) % capacityFrames
                    availableFrames -= 1
                    trimmedFrames += 1
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

        var ratio = 1.0
        if !senderIdle {
            // Ignore the packet-size sawtooth and move at most 1 frame per 1000.
            let alpha = Double(frameCount) / (96_000 + Double(frameCount))
            let error = Double(availableFrames - targetFrames)
            filteredFillError += alpha * (error - filteredFillError)
            ratio += min(0.001, max(-0.001, filteredFillError * 0.000004))
        }
        var produced = 0
        while produced < frameCount && availableFrames > 0 {
            let base = readIndex * 2
            let next = availableFrames > 1 ? ((readIndex + 1) % capacityFrames) * 2 : base
            let mix = Float(fractionalOffset)
            let gain = Float(240 - fadeInFrames) / 240
            let l = (buffer[base] + (buffer[next] - buffer[base]) * mix) * gain
            let r = (buffer[base + 1] + (buffer[next + 1] - buffer[base + 1]) * mix) * gain
            fadeInFrames = max(0, fadeInFrames - 1)
            left[produced] = l
            right?[produced] = r
            lastL = l
            lastR = r
            produced += 1
            fractionalOffset += ratio
            let consumed = Int(fractionalOffset)
            fractionalOffset -= Double(consumed)
            let actual = min(consumed, availableFrames)
            readIndex = (readIndex + actual) % capacityFrames
            availableFrames -= actual
        }

        if produced < frameCount {
            primed = false
            pendingUnderrun = !senderIdle
            filteredFillError = 0
            fractionalOffset = 0
            var l = lastL
            var r = lastR
            for i in produced..<frameCount {
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
