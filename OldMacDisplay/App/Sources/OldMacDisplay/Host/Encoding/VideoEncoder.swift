import Foundation
import VideoToolbox
import CoreMedia
import OldMacDisplayShared

/// Hardware H.264/HEVC encoder tuned for interactive desktop streaming.
///
/// Configured for low latency rather than best compression: real-time mode, no
/// frame reordering (so no B-frames and no reordering delay), and a short GOP so
/// a Receiver that reconnects or drops a frame recovers quickly.
final class VideoEncoder {

    struct Configuration: Equatable {
        var codec: VideoCodec
        var width: Int
        var height: Int
        var frameRate: Int
        var bitrateBPS: Int
    }

    enum EncoderError: Error {
        case sessionCreationFailed(OSStatus)
        case propertyFailed(String, OSStatus)
        case encodeFailed(OSStatus)
        case noFormatDescription
        case parameterSetsUnavailable(OSStatus)
    }

    /// Called on the encoder's callback thread for every produced packet.
    /// Parameter sets arrive immediately before the keyframe they describe.
    var onPacket: ((VideoPacket) -> Void)?

    private(set) var configuration: Configuration
    private var session: VTCompressionSession?
    private let log = Log(.encoder)

    /// Parameter sets are resent with every keyframe, but only when they change
    /// or a Receiver asked for a keyframe (it may have lost them), to avoid a
    /// pointless few hundred bytes on every GOP.
    private var lastParameterSets: [Data]?

    /// Guards the two request flags, which are set from whichever thread asks
    /// for a keyframe and read on the capture and encoder-callback threads.
    private let flagLock = NSLock()
    private var nextFrameForcesKeyframe = false
    private var resendParameterSets = false

    init(configuration: Configuration) throws {
        self.configuration = configuration
        try createSession()
    }

    deinit { invalidate() }

    // MARK: - Session

    private func createSession() throws {
        let codecType: CMVideoCodecType = configuration.codec == .hevc
            ? kCMVideoCodecType_HEVC
            : kCMVideoCodecType_H264

        var encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            // Fail loudly rather than silently falling back to the software
            // encoder, which cannot sustain 1080p60 at low latency.
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
        ]

        // VideoToolbox's dedicated low-latency mode: constrains the rate
        // controller so it never buffers frames to smooth out bitrate. Measured
        // without it, the encoder held roughly one full frame (18 ms at 57 fps),
        // which lands directly in the glass-to-glass budget.
        if #available(macOS 11.3, *) {
            encoderSpec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true
        }

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(configuration.width),
            height: Int32(configuration.height),
            codecType: codecType,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session)

        guard status == noErr, let created = session else {
            log.error("VTCompressionSessionCreate failed: \(status)")
            throw EncoderError.sessionCreationFailed(status)
        }
        self.session = created

        try applyLowLatencyProperties(to: created)
        VTCompressionSessionPrepareToEncodeFrames(created)

        log.info("Encoder ready: \(configuration.codec.rawValue) \(configuration.width)x\(configuration.height) @\(configuration.frameRate) \(configuration.bitrateBPS / 1_000_000) Mbps")
    }

    private func applyLowLatencyProperties(to session: VTCompressionSession) throws {
        // Which properties this encoder actually accepts. Support varies by
        // codec, by hardware, and with the low-latency rate controller, so ask
        // rather than assume.
        var supportedDictionary: CFDictionary?
        VTSessionCopySupportedPropertyDictionary(session,
                                                 supportedPropertyDictionaryOut: &supportedDictionary)
        let supported = (supportedDictionary as? [String: Any]) ?? [:]

        /// Required: the stream is not worth starting without these.
        func set(_ key: CFString, _ value: CFTypeRef, _ name: String) throws {
            let status = VTSessionSetProperty(session, key: key, value: value)
            guard status == noErr else {
                log.error("Setting \(name) failed: \(status)")
                throw EncoderError.propertyFailed(name, status)
            }
        }

        /// Optional tuning: nice to have, never a reason to fail.
        ///
        /// An earlier build made these fatal, and one unsupported tuning knob
        /// (`MaxFrameDelayCount` under the low-latency rate controller) took the
        /// whole stream down. A property that only makes things smoother must
        /// never be able to stop them working.
        func tune(_ key: CFString, _ value: CFTypeRef, _ name: String) {
            guard supported[key as String] != nil else {
                log.info("Encoder does not support \(name); skipping")
                return
            }
            let status = VTSessionSetProperty(session, key: key, value: value)
            if status != noErr {
                log.notice("Setting \(name) failed (\(status)); continuing without it")
            }
        }

        // Real-time: encode no slower than capture, trading compression for latency.
        try set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue, "RealTime")
        // No B-frames. Reordering would hold frames back to improve compression,
        // which is exactly the wrong trade for a desktop being dragged around.
        try set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse, "AllowFrameReordering")

        let profile: CFString = configuration.codec == .hevc
            ? kVTProfileLevel_HEVC_Main_AutoLevel
            // High profile buys the 8x8 transform, which noticeably sharpens
            // small text. Haswell (2013 iMac) decodes High in hardware.
            : kVTProfileLevel_H264_High_AutoLevel
        try set(kVTCompressionPropertyKey_ProfileLevel, profile, "ProfileLevel")

        try set(kVTCompressionPropertyKey_AverageBitRate,
                NSNumber(value: configuration.bitrateBPS), "AverageBitRate")
        try set(kVTCompressionPropertyKey_ExpectedFrameRate,
                NSNumber(value: configuration.frameRate), "ExpectedFrameRate")

        // Long GOP. The transport is TCP, so nothing is lost on the wire, and
        // every path that can desynchronise the Receiver (a dropped frame on
        // either side, a late join, a reconnect) explicitly asks for an IDR.
        // Periodic keyframes therefore only cost bitrate: on a mostly static
        // desktop one every 2 s was the single largest consumer, and it showed
        // as a visible quality pulse on small text. Kept finite as a safety
        // net against a missed request.
        try set(kVTCompressionPropertyKey_MaxKeyFrameInterval,
                NSNumber(value: configuration.frameRate * VideoEncoder.keyframeIntervalSeconds),
                "MaxKeyFrameInterval")
        try set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                NSNumber(value: Double(VideoEncoder.keyframeIntervalSeconds)),
                "MaxKeyFrameIntervalDuration")

        // Hard cap slightly above the average so a burst cannot flood the link
        // and build a multi-second queue. [bytes, seconds].
        let capBytes = Double(configuration.bitrateBPS) * 1.5 / 8.0
        tune(kVTCompressionPropertyKey_DataRateLimits,
             [NSNumber(value: capBytes), NSNumber(value: 1.0)] as CFArray, "DataRateLimits")

        // Emit every frame as soon as it is encoded, rather than holding some
        // back to improve rate control. The low-latency rate controller already
        // implies this and then rejects the property outright, so it is only
        // attempted where the encoder advertises it.
        tune(kVTCompressionPropertyKey_MaxFrameDelayCount,
             NSNumber(value: 0), "MaxFrameDelayCount")

        // Power efficiency deliberately off: it lets the encoder batch work,
        // which shows up directly as jitter.
        if #available(macOS 11.0, *) {
            tune(kVTCompressionPropertyKey_MaximizePowerEfficiency,
                 kCFBooleanFalse, "MaximizePowerEfficiency")
        }
    }

    static let keyframeIntervalSeconds = 30

    func invalidate() {
        guard let session = session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    // MARK: - Encoding

    /// Submits one captured frame. Returns immediately; output arrives on
    /// `onPacket` from the encoder's own thread.
    func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, forceKeyframe: Bool = false) {
        guard let session = session else { return }

        let submittedAt = MonotonicClock.now()
        var properties: CFDictionary?
        if forceKeyframe {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary
        }

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil) { [weak self] status, _, sampleBuffer in
                guard let self = self else { return }
                guard status == noErr else {
                    self.log.error("Encode failed: \(status)")
                    return
                }
                guard let sampleBuffer = sampleBuffer else {
                    // Not an error: VideoToolbox calls back with no sample
                    // buffer when a frame produced no output, for instance one
                    // the rate controller dropped. Logging it as a failure sent
                    // a misleading "Encode callback failed: 0" (0 being noErr).
                    self.log.debug("Frame produced no output")
                    return
                }
                self.handleEncoded(sampleBuffer, submittedAt: submittedAt)
            }

        if status != noErr {
            log.error("VTCompressionSessionEncodeFrame failed: \(status)")
        }
    }

    /// Forces the next frame to be an IDR, with its parameter sets. Used when
    /// the Receiver reconnects or explicitly asks for one after loss.
    func requestKeyframe() {
        flagLock.lock()
        nextFrameForcesKeyframe = true
        resendParameterSets = true
        flagLock.unlock()
    }

    func consumeKeyframeRequest() -> Bool {
        flagLock.lock()
        defer { flagLock.unlock() }
        let requested = nextFrameForcesKeyframe
        nextFrameForcesKeyframe = false
        return requested
    }

    private func consumeParameterSetResend() -> Bool {
        flagLock.lock()
        defer { flagLock.unlock() }
        let requested = resendParameterSets
        resendParameterSets = false
        return requested
    }

    /// Adjusts bitrate on a live session, without tearing the encoder down.
    func updateBitrate(_ bitrateBPS: Int) {
        guard let session = session, bitrateBPS != configuration.bitrateBPS else { return }
        configuration.bitrateBPS = bitrateBPS
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: bitrateBPS))
        let capBytes = Double(bitrateBPS) * 1.5 / 8.0
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits,
                             value: [NSNumber(value: capBytes), NSNumber(value: 1.0)] as CFArray)
        log.info("Bitrate now \(bitrateBPS / 1_000_000) Mbps")
    }

    // MARK: - Output

    private func handleEncoded(_ sampleBuffer: CMSampleBuffer, submittedAt: Double) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let encodeMicros = UInt32(max(0, (MonotonicClock.now() - submittedAt) * 1_000_000))
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsMicros = UInt64(max(0, CMTimeGetSeconds(pts) * 1_000_000))
        let isKeyframe = Self.isKeyframe(sampleBuffer)

        // Parameter sets must precede the keyframe they describe, so the
        // Receiver can build its decoder before the first frame arrives.
        if isKeyframe, let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
            emitParameterSetsIfChanged(formatDescription, ptsMicros: ptsMicros)
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0,
                                                 lengthAtOffsetOut: nil,
                                                 totalLengthOut: &totalLength,
                                                 dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let pointer = dataPointer else {
            log.error("CMBlockBufferGetDataPointer failed: \(status)")
            return
        }

        // Zero-copy: the packet's Data points into the CMBlockBuffer and keeps
        // the sample buffer alive until the transport has released the bytes.
        // VideoToolbox's output is a single contiguous block in practice; the
        // copying path is only for the case where it is not.
        var contiguousLength = 0
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0,
                                    lengthAtOffsetOut: &contiguousLength,
                                    totalLengthOut: nil, dataPointerOut: nil)
        let payload: Data
        if contiguousLength == totalLength {
            let retained = sampleBuffer
            payload = Data(bytesNoCopy: UnsafeMutableRawPointer(pointer), count: totalLength,
                           deallocator: .custom { _, _ in _ = retained })
        } else {
            var copy = Data(count: totalLength)
            let copyStatus = copy.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
                return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0,
                                                  dataLength: totalLength, destination: base)
            }
            guard copyStatus == kCMBlockBufferNoErr else {
                log.error("CMBlockBufferCopyDataBytes failed: \(copyStatus)")
                return
            }
            payload = copy
        }

        onPacket?(VideoPacket(kind: .accessUnit,
                              isKeyframe: isKeyframe,
                              presentationTimeMicros: ptsMicros,
                              encodeDurationMicros: encodeMicros,
                              payload: payload))
    }

    private func emitParameterSetsIfChanged(_ formatDescription: CMFormatDescription,
                                            ptsMicros: UInt64) {
        guard let sets = try? Self.parameterSets(from: formatDescription,
                                                 codec: configuration.codec) else {
            log.error("Could not read parameter sets from format description")
            return
        }
        let forced = consumeParameterSetResend()
        guard forced || sets.sets != lastParameterSets else { return }
        lastParameterSets = sets.sets

        log.info("Sending parameter sets (\(sets.sets.count) sets, NAL length \(sets.nalUnitHeaderLength), \(forced ? "requested" : "changed"))")
        onPacket?(VideoPacket(kind: .parameterSets,
                              isKeyframe: true,
                              nalUnitHeaderLength: UInt8(sets.nalUnitHeaderLength),
                              presentationTimeMicros: ptsMicros,
                              payload: ParameterSets.encode(sets.sets)))
    }

    /// Extracts SPS/PPS (H.264) or VPS/SPS/PPS (HEVC) from a format description.
    static func parameterSets(from formatDescription: CMFormatDescription,
                              codec: VideoCodec) throws -> (sets: [Data], nalUnitHeaderLength: Int) {
        var count = 0
        var nalUnitHeaderLength: Int32 = 4

        let countStatus: OSStatus
        if codec == .hevc {
            countStatus = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                formatDescription, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalUnitHeaderLength)
        } else {
            countStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalUnitHeaderLength)
        }
        guard countStatus == noErr else {
            throw EncoderError.parameterSetsUnavailable(countStatus)
        }

        var sets: [Data] = []
        sets.reserveCapacity(count)
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status: OSStatus
            if codec == .hevc {
                status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    formatDescription, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            } else {
                status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    formatDescription, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            }
            guard status == noErr, let bytes = pointer else {
                throw EncoderError.parameterSetsUnavailable(status)
            }
            sets.append(Data(bytes: bytes, count: size))
        }
        return (sets, Int(nalUnitHeaderLength))
    }

    private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                        createIfNecessary: false)
                as? [[CFString: Any]],
              let first = attachments.first else {
            // No attachments at all means not-a-sync-sample was never set.
            return true
        }
        // A frame is a keyframe unless it is explicitly marked "not sync".
        return !((first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
    }
}
