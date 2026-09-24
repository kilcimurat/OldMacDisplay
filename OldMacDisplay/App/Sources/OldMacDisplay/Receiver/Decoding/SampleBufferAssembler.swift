import Foundation
import CoreMedia
import VideoToolbox
import OldMacDisplayShared

/// Rebuilds `CMSampleBuffer`s from the packets arriving on the video channel.
///
/// The Host sends the bitstream in AVCC form (length-prefixed NAL units) exactly
/// as VideoToolbox produced it, plus the parameter sets. That is precisely what
/// CoreMedia needs to construct a decodable sample buffer, so no bitstream
/// parsing or Annex-B conversion happens anywhere in this project.
///
/// Every API used here exists on macOS 10.15.
final class SampleBufferAssembler {

    enum AssemblerError: Error {
        case formatDescriptionFailed(OSStatus)
        case blockBufferFailed(OSStatus)
        case sampleBufferFailed(OSStatus)
        case noFormatDescription
        case unsupportedCodec(VideoCodec)
    }

    private(set) var formatDescription: CMVideoFormatDescription?
    private var codec: VideoCodec = .h264
    private let log = Log(.decoder)

    /// True once parameter sets have been received and a decoder can be built.
    var isReady: Bool { formatDescription != nil }

    func configure(codec: VideoCodec) {
        if self.codec != codec {
            self.codec = codec
            reset()
        }
    }

    func reset() {
        formatDescription = nil
    }

    /// Builds the format description from SPS/PPS (or VPS/SPS/PPS).
    func setParameterSets(_ sets: [Data], nalUnitHeaderLength: Int) throws {
        guard !sets.isEmpty else { throw AssemblerError.noFormatDescription }

        // Pointers must stay valid across the CoreMedia call, so the Data
        // buffers are pinned for the duration rather than copied out.
        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        var pinned: [UnsafeMutableRawPointer] = []
        defer { pinned.forEach { $0.deallocate() } }

        for set in sets {
            let raw = UnsafeMutableRawPointer.allocate(byteCount: set.count,
                                                       alignment: MemoryLayout<UInt8>.alignment)
            set.copyBytes(to: raw.assumingMemoryBound(to: UInt8.self), count: set.count)
            pinned.append(raw)
            pointers.append(UnsafePointer(raw.assumingMemoryBound(to: UInt8.self)))
            sizes.append(set.count)
        }

        var description: CMVideoFormatDescription?
        let status: OSStatus

        if codec == .hevc {
            // HEVC needs macOS 10.13+; a 2013 iMac will never negotiate it, but
            // the guard keeps the code honest on newer Receivers.
            guard #available(macOS 10.13, *) else {
                throw AssemblerError.unsupportedCodec(.hevc)
            }
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: &pointers,
                parameterSetSizes: &sizes,
                nalUnitHeaderLength: Int32(nalUnitHeaderLength),
                extensions: nil,
                formatDescriptionOut: &description)
        } else {
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: &pointers,
                parameterSetSizes: &sizes,
                nalUnitHeaderLength: Int32(nalUnitHeaderLength),
                formatDescriptionOut: &description)
        }

        guard status == noErr, let created = description else {
            log.error("Creating format description failed: \(status)")
            throw AssemblerError.formatDescriptionFailed(status)
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(created)
        log.info("Decoder configured: \(codec.rawValue) \(dimensions.width)x\(dimensions.height), \(sets.count) parameter sets")
        formatDescription = created
    }

    /// Wraps one compressed access unit in a `CMSampleBuffer` ready to display.
    func makeSampleBuffer(from packet: VideoPacket) throws -> CMSampleBuffer {
        guard let formatDescription = formatDescription else {
            throw AssemblerError.noFormatDescription
        }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: packet.payload.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: packet.payload.count,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let block = blockBuffer else {
            throw AssemblerError.blockBufferFailed(status)
        }

        status = packet.payload.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block,
                                                 offsetIntoDestination: 0,
                                                 dataLength: packet.payload.count)
        }
        guard status == kCMBlockBufferNoErr else {
            throw AssemblerError.blockBufferFailed(status)
        }

        // Microsecond timescale matches the wire format exactly, so no rounding.
        let pts = CMTime(value: CMTimeValue(packet.presentationTimeMicros), timescale: 1_000_000)
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: pts,
                                        decodeTimeStamp: .invalid)
        var sampleSize = packet.payload.count
        var sampleBuffer: CMSampleBuffer?

        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer)

        guard status == noErr, let created = sampleBuffer else {
            throw AssemblerError.sampleBufferFailed(status)
        }

        // Display as soon as decoded rather than scheduling against a timebase.
        // This is what keeps end-to-end latency at one frame instead of letting
        // the layer build a presentation queue.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            created, createIfNecessary: true) as? [CFMutableDictionary],
           let first = attachments.first {
            CFDictionarySetValue(
                first,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        return created
    }
}
