import Foundation
import VideoToolbox
import CoreMedia

struct EncodedFrame {
    let data: Data
    let keyframe: Bool
    let format: VideoFormat?
}

/// Hardware HEVC / H.264 encoder (M2 media engine) tuned for interactive latency:
/// real-time mode, no B-frames, no periodic keyframes (TCP is lossless; the
/// client asks for one when it needs it).
final class VideoEncoder {
    let width: Int32
    let height: Int32
    let codec: VideoCodec
    private(set) var lowLatency = false
    private var session: VTCompressionSession?

    init?(width: Int32, height: Int32, codec: VideoCodec, fps: Int, bitrate: Int) {
        self.width = width
        self.height = height
        self.codec = codec
        let type = codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        let specs: [[CFString: Any]] = [
            [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
             kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true],
            [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true],
            [:],
        ]
        for (i, spec) in specs.enumerated() {
            var s: VTCompressionSession?
            let st = VTCompressionSessionCreate(allocator: nil, width: width, height: height, codecType: type,
                                                encoderSpecification: spec as CFDictionary,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &s)
            if st == noErr, let s {
                session = s
                lowLatency = i == 0
                break
            }
        }
        guard let session else { return nil }

        func set(_ k: CFString, _ v: CFTypeRef) { VTSessionSetProperty(session, key: k, value: v) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ProfileLevel,
            codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 1_000_000 as NSNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 100_000 as NSNumber)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as NSNumber)
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        setBitrate(bitrate)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
    }

    func setBitrate(_ bps: Int) {
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bps as NSNumber)
        // Allow short bursts (e.g. a sharp keyframe) up to 2x average within one second.
        let limits = [NSNumber(value: Double(bps) * 2 / 8), NSNumber(value: 1.0)] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits)
    }

    /// `completion` is called on a VideoToolbox thread.
    func encode(_ pb: CVPixelBuffer, forceKeyframe: Bool, completion: @escaping (EncodedFrame?) -> Void) {
        guard let session else { completion(nil); return }
        let props: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let pts = CMTime(value: Int64(monotonicMicros()), timescale: 1_000_000)
        let codec = self.codec
        let st = VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: pts,
                                                 duration: .invalid, frameProperties: props,
                                                 infoFlagsOut: nil) { status, flags, sb in
            guard status == noErr, !flags.contains(.frameDropped), let sb else { completion(nil); return }
            completion(VideoEncoder.package(sb, codec: codec))
        }
        if st != noErr { completion(nil) }
    }

    private static func package(_ sb: CMSampleBuffer, codec: VideoCodec) -> EncodedFrame? {
        guard let bb = CMSampleBufferGetDataBuffer(sb) else { return nil }
        var notSync = false
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false), CFArrayGetCount(arr) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFDictionary.self)
            if let v = CFDictionaryGetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()) {
                notSync = CFBooleanGetValue(unsafeBitCast(v, to: CFBoolean.self))
            }
        }
        let key = !notSync

        let len = CMBlockBufferGetDataLength(bb)
        var data = Data(count: len)
        let st = data.withUnsafeMutableBytes { ptr in
            CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: ptr.baseAddress!)
        }
        guard st == kCMBlockBufferNoErr else { return nil }

        var format: VideoFormat?
        if key, let fd = CMSampleBufferGetFormatDescription(sb) {
            format = parameterSets(fd, codec: codec)
        }
        return EncodedFrame(data: data, keyframe: key, format: format)
    }

    private static func parameterSets(_ fd: CMFormatDescription, codec: VideoCodec) -> VideoFormat? {
        var count = 0
        var nalLen: Int32 = 0
        var sets = [Data]()
        if codec == .hevc {
            guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil,
                    parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLen) == noErr
            else { return nil }
            for i in 0..<count {
                var p: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &p,
                        parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                   let p { sets.append(Data(bytes: p, count: size)) }
            }
        } else {
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil,
                    parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLen) == noErr
            else { return nil }
            for i in 0..<count {
                var p: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &p,
                        parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                   let p { sets.append(Data(bytes: p, count: size)) }
            }
        }
        guard nalLen == 4 else { NSLog("PocketMac: unexpected NAL length \(nalLen)"); return nil }
        let dims = CMVideoFormatDescriptionGetDimensions(fd)
        return VideoFormat(codec: codec, width: UInt16(dims.width), height: UInt16(dims.height), parameterSets: sets)
    }
}
