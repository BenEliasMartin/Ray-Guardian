import Foundation
import CoreMedia
import CoreImage
import VideoToolbox
import UIKit

/// Converts real DAT raw buffers or compressed H.264/HEVC packets to fresh images.
/// Every compressed packet is decoded to preserve inter-frame references; the capture gate samples
/// the resulting images. Decode errors return nil, never an old image with a new evidence timestamp.
final class StreamImageDecoder: @unchecked Sendable {
    private let lock = NSLock(), context = CIContext(options:[.useSoftwareRenderer:true])
    private var session: VTDecompressionSession?, closed = false, failures = 0
    private final class PixelResult: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer: CVPixelBuffer?
        func set(_ value: CVPixelBuffer) { lock.lock(); buffer = value; lock.unlock() }
        func get() -> CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return buffer }
    }
    func decode(_ sample: CMSampleBuffer) -> UIImage? {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return nil }
        if let pixels = CMSampleBufferGetImageBuffer(sample) { return image(pixels) }
        guard CMSampleBufferGetDataBuffer(sample) != nil, let format = CMSampleBufferGetFormatDescription(sample) else { return nil }
        if let existing = session,!VTDecompressionSessionCanAcceptFormatDescription(existing,formatDescription:format) {
            VTDecompressionSessionInvalidate(existing); session = nil
        }
        if session == nil {
            let attributes = [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA] as CFDictionary
            let specification = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder as String:false] as CFDictionary
            guard VTDecompressionSessionCreate(allocator:kCFAllocatorDefault,formatDescription:format,decoderSpecification:specification,imageBufferAttributes:attributes,outputCallback:nil,decompressionSessionOut:&session) == noErr else { return nil }
        }
        guard let session else { return nil }
        let result = PixelResult()
        // Empty flags keep the output handler synchronous; no asynchronous decode work outlives stop.
        let status = VTDecompressionSessionDecodeFrame(session,sampleBuffer:sample,flags:[],infoFlagsOut:nil) { status,_,pixels,_,_ in
            if status == noErr,let pixels { result.set(pixels) }
        }
        guard status == noErr else {
            failures += 1
            if failures >= 3 { VTDecompressionSessionInvalidate(session); self.session = nil; failures = 0 }
            return nil
        }
        failures = 0
        guard let pixels = result.get() else { return nil }; return image(pixels)
    }
    private func image(_ pixels: CVPixelBuffer) -> UIImage? {
        let rect = CGRect(x:0,y:0,width:CVPixelBufferGetWidth(pixels),height:CVPixelBufferGetHeight(pixels))
        guard let cg = context.createCGImage(CIImage(cvPixelBuffer:pixels),from:rect) else { return nil }
        return UIImage(cgImage:cg)
    }
    func close() { lock.lock(); defer { lock.unlock() }; closed = true; if let session { VTDecompressionSessionInvalidate(session) }; session = nil }
    deinit { close() }
}
