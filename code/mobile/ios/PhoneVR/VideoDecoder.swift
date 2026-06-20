import VideoToolbox
import CoreMedia
import CoreVideo

/// Decodes H.264 / HEVC NAL data received from the ALVR server using VideoToolbox.
/// Decoded frames are delivered as CVPixelBuffer via `onFrame`.
final class VideoDecoder {
    var onFrame: ((CVPixelBuffer, UInt64) -> Void)?

    private var session: VTDecompressionSession?
    private var formatDesc: CMFormatDescription?
    private var codec: AlvrCodec_Tag = ALVR_CODEC_H264
    private var spsData: [UInt8] = []
    private var ppsData: [UInt8] = []
    private var vpsData: [UInt8] = []  // HEVC only

    // MARK: - Configuration

    func configure(codec: AlvrCodec_Tag, configNal: [UInt8]) {
        self.codec = codec
        parseParameterSets(from: configNal)
        rebuildSession()
    }

    // MARK: - Frame submission

    func submitNal(timestampNs: UInt64, nal: [UInt8]) {
        guard let session else { return }
        guard let sampleBuf = makeSampleBuffer(from: nal, timestampNs: timestampNs) else { return }

        let flags: VTDecodeFrameFlags = []
        // Wrap (self, timestamp) in a heap object and transfer ownership to the callback.
        let ctx = VideoDecoderCallbackContext(decoder: self, timestampNs: timestampNs)
        let ctxPtr = UnsafeMutableRawPointer(Unmanaged.passRetained(ctx).toOpaque())
        VTDecompressionSessionDecodeFrame(session,
                                          sampleBuffer: sampleBuf,
                                          flags: flags,
                                          frameRefcon: ctxPtr,
                                          infoFlagsOut: nil)
    }

    // MARK: - Private helpers

    private func parseParameterSets(from nal: [UInt8]) {
        var units: [[UInt8]] = []
        var i = 0
        var start = 0
        while i + 2 < nal.count {
            if nal[i] == 0 && nal[i+1] == 0 {
                if nal[i+2] == 1 {
                    if i > start { units.append(Array(nal[start..<i])) }
                    start = i + 3; i += 3; continue
                } else if i + 3 < nal.count && nal[i+2] == 0 && nal[i+3] == 1 {
                    if i > start { units.append(Array(nal[start..<i])) }
                    start = i + 4; i += 4; continue
                }
            }
            i += 1
        }
        if start < nal.count { units.append(Array(nal[start...])) }

        for unit in units where !unit.isEmpty {
            let naluType = codec == ALVR_CODEC_H264
                ? Int(unit[0] & 0x1F)
                : Int((unit[0] >> 1) & 0x3F)
            if codec == ALVR_CODEC_H264 {
                switch naluType { case 7: spsData = unit; case 8: ppsData = unit; default: break }
            } else {
                switch naluType { case 32: vpsData = unit; case 33: spsData = unit; case 34: ppsData = unit; default: break }
            }
        }
    }

    private func rebuildSession() {
        session = nil; formatDesc = nil
        var desc: CMFormatDescription?
        var status: OSStatus

        if codec == ALVR_CODEC_H264 {
            guard !spsData.isEmpty, !ppsData.isEmpty else { return }
            status = spsData.withUnsafeBufferPointer { spsBuf in
                ppsData.withUnsafeBufferPointer { ppsBuf in
                    let ptrs: [UnsafePointer<UInt8>] = [spsBuf.baseAddress!, ppsBuf.baseAddress!]
                    let sizes: [Int] = [spsData.count, ppsData.count]
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: nil, parameterSetCount: 2,
                        parameterSetPointers: ptrs, parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
                }
            }
        } else {
            guard !vpsData.isEmpty, !spsData.isEmpty, !ppsData.isEmpty else { return }
            status = vpsData.withUnsafeBufferPointer { vpsBuf in
                spsData.withUnsafeBufferPointer { spsBuf in
                    ppsData.withUnsafeBufferPointer { ppsBuf in
                        let ptrs: [UnsafePointer<UInt8>] = [vpsBuf.baseAddress!, spsBuf.baseAddress!, ppsBuf.baseAddress!]
                        let sizes: [Int] = [vpsData.count, spsData.count, ppsData.count]
                        return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                            allocator: nil, parameterSetCount: 3,
                            parameterSetPointers: ptrs, parameterSetSizes: sizes,
                            nalUnitHeaderLength: 4, extensions: nil,
                            formatDescriptionOut: &desc)
                    }
                }
            }
        }
        guard status == noErr, let desc else { return }
        formatDesc = desc

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        // The self pointer is passed as decompressionOutputRefCon and retrieved in the
        // top-level C callback below.  Using passUnretained here is safe because the
        // session is destroyed in rebuildSession() / deinit before self could go away.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var cbRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: vtOutputCallback,
            decompressionOutputRefCon: selfPtr)

        var newSession: VTDecompressionSession?
        VTDecompressionSessionCreate(allocator: nil,
                                     formatDescription: desc,
                                     decoderSpecification: nil,
                                     imageBufferAttributes: attrs as CFDictionary,
                                     outputCallback: &cbRecord,
                                     decompressionSessionOut: &newSession)
        session = newSession
    }

    private func makeSampleBuffer(from annexBNal: [UInt8], timestampNs: UInt64) -> CMSampleBuffer? {
        guard let formatDesc else { return nil }

        // Convert Annex-B start codes to AVCC 4-byte length prefixes.
        var avcc = [UInt8]()
        var i = 0
        while i < annexBNal.count {
            var skip = 0
            if i + 3 <= annexBNal.count && annexBNal[i] == 0 && annexBNal[i+1] == 0 {
                if annexBNal[i+2] == 1 { skip = 3 }
                else if i + 4 <= annexBNal.count && annexBNal[i+2] == 0 && annexBNal[i+3] == 1 { skip = 4 }
            }
            if skip > 0 {
                var end = i + skip
                while end + 3 < annexBNal.count {
                    if annexBNal[end] == 0 && annexBNal[end+1] == 0 &&
                       (annexBNal[end+2] == 1 || (annexBNal[end+2] == 0 && end + 3 < annexBNal.count && annexBNal[end+3] == 1)) { break }
                    end += 1
                }
                let naluLen = end - (i + skip)
                withUnsafeBytes(of: UInt32(naluLen).bigEndian) { avcc.append(contentsOf: $0) }
                avcc.append(contentsOf: annexBNal[(i + skip)..<end])
                i = end
            } else { i += 1 }
        }
        guard !avcc.isEmpty else { return nil }

        var blockBuf: CMBlockBuffer?
        var status = avcc.withUnsafeMutableBytes { ptr -> OSStatus in
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: ptr.baseAddress,
                blockLength: avcc.count, blockAllocator: kCFAllocatorNull,
                customBlockSource: nil, offsetToData: 0, dataLength: avcc.count,
                flags: 0, blockBufferOut: &blockBuf)
        }
        guard status == noErr, let blockBuf else { return nil }

        let pts = CMTime(value: CMTimeValue(timestampNs), timescale: 1_000_000_000)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sampleBuf: CMSampleBuffer?
        status = CMSampleBufferCreateReady(allocator: nil, dataBuffer: blockBuf,
                                           formatDescription: formatDesc,
                                           sampleCount: 1,
                                           sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                           sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                           sampleBufferOut: &sampleBuf)
        return status == noErr ? sampleBuf : nil
    }
}

// MARK: - VideoToolbox C callback
// Must be a top-level function (not a closure) to be used as @convention(c).

private final class VideoDecoderCallbackContext {
    weak var decoder: VideoDecoder?
    let timestampNs: UInt64
    init(decoder: VideoDecoder, timestampNs: UInt64) {
        self.decoder = decoder
        self.timestampNs = timestampNs
    }
}

private func vtOutputCallback(
    refCon: UnsafeMutableRawPointer?,
    frameRefCon: UnsafeMutableRawPointer?,
    status: OSStatus,
    _: VTDecodeInfoFlags,
    imageBuffer: CVImageBuffer?,
    _: CMTime,
    _: CMTime
) {
    guard status == noErr, let imageBuffer else { return }
    guard let frameRefCon else { return }
    // frameRefCon is a +1 retained VideoDecoderCallbackContext.
    let ctx = Unmanaged<VideoDecoderCallbackContext>.fromOpaque(frameRefCon).takeRetainedValue()
    ctx.decoder?.onFrame?(imageBuffer, ctx.timestampNs)
}
