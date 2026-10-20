import Foundation
import CoreMedia

extension VideoFormat {
    /// Builds the decoder format description from the SPS/PPS(/VPS) sent with each keyframe.
    func makeFormatDescription() -> CMVideoFormatDescription? {
        guard !parameterSets.isEmpty else { return nil }
        let bufs = parameterSets.map { d -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: max(d.count, 1))
            d.copyBytes(to: p, count: d.count)
            return p
        }
        defer { bufs.forEach { $0.deallocate() } }
        let ptrs = bufs.map { UnsafePointer($0) }
        let sizes = parameterSets.map { $0.count }
        var fd: CMFormatDescription?
        let st: OSStatus
        if codec == .hevc {
            st = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: ptrs.count, parameterSetPointers: ptrs,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fd)
        } else {
            st = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: ptrs.count, parameterSetPointers: ptrs,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
        }
        return st == noErr ? fd : nil
    }
}

extension VideoFrame {
    /// Wraps the compressed frame for AVSampleBufferDisplayLayer / VTDecompressionSession.
    func makeSampleBuffer(_ fd: CMVideoFormatDescription, displayImmediately: Bool) -> CMSampleBuffer? {
        let len = data.count
        guard len > 0 else { return nil }
        var bb: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: len,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: len, flags: 0,
                                                 blockBufferOut: &bb) == kCMBlockBufferNoErr, let bb else { return nil }
        let copied = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: len)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: Int64(captureMicros), timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var size = len
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: bb, formatDescription: fd,
                                        sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                        sampleBufferOut: &sb) == noErr, let sb else { return nil }
        if let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true), CFArrayGetCount(att) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(att, 0), to: CFMutableDictionary.self)
            if displayImmediately {
                CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            if !keyframe {
                CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sb
    }
}
