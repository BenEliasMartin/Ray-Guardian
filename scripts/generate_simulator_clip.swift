// Generates original, synthetic test footage. No external footage or camera is used.
// Run on macOS: swift scripts/generate_simulator_clip.swift app/src/debug/assets/simulator_path.mp4
import AppKit
import AVFoundation
import CoreVideo
import VideoToolbox

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "simulator_path.mp4"
let url = URL(fileURLWithPath: output)
try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
if FileManager.default.fileExists(atPath: output) { try FileManager.default.removeItem(at: url) }
let width = 360, height = 640, fps: Int32 = 15, frameCount = 225
let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.hevc,
    AVVideoWidthKey: width, AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 500_000, AVVideoMaxKeyFrameIntervalKey: 15,
        AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel]
])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
    kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
    kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
])
writer.add(input)
guard writer.startWriting() else { fatalError("Could not start video writer") }
writer.startSession(atSourceTime: .zero)

func polygon(_ ctx: CGContext, _ points: [CGPoint], _ color: NSColor) {
    ctx.setFillColor(color.cgColor); ctx.beginPath(); ctx.addLines(between: points); ctx.closePath(); ctx.fillPath()
}
for frame in 0..<frameCount {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
    var image: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &image)
    let buffer = image!
    CVPixelBufferLockBaseAddress(buffer, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
    let t = Double(frame) / Double(fps)
    ctx.setFillColor(NSColor(calibratedRed: 0.64, green: 0.83, blue: 0.92, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    // A simple first-person walking scene, drawn from the bottom up.
    let bob = sin(t * 5) * 3
    ctx.saveGState(); ctx.translateBy(x: sin(t * 1.5) * 3, y: bob)
    ctx.setFillColor(NSColor(calibratedRed: 0.27, green: 0.48, blue: 0.31, alpha: 1).cgColor)
    ctx.fill(CGRect(x: -10, y: -10, width: 380, height: 310))
    polygon(ctx, [CGPoint(x: 20, y: 0), CGPoint(x: 148, y: 310), CGPoint(x: 212, y: 310), CGPoint(x: 340, y: 0)], .init(calibratedWhite: 0.55, alpha: 1))
    polygon(ctx, [CGPoint(x: -10, y: 0), CGPoint(x: 130, y: 310), CGPoint(x: 148, y: 310), CGPoint(x: 20, y: 0)], .init(calibratedWhite: 0.78, alpha: 1))
    polygon(ctx, [CGPoint(x: 340, y: 0), CGPoint(x: 212, y: 310), CGPoint(x: 230, y: 310), CGPoint(x: 370, y: 0)], .init(calibratedWhite: 0.78, alpha: 1))
    for index in 0..<12 {
        let phase = (Double(index) / 12 + t * 0.16).truncatingRemainder(dividingBy: 1)
        let y = 306 - phase * phase * 306
        let half = 2 + phase * 7
        ctx.setFillColor(NSColor(calibratedRed: 0.96, green: 0.87, blue: 0.56, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 180 - half / 2, y: y, width: half, height: 3 + phase * 15))
    }
    for side in [-1.0, 1.0] {
        for index in 0..<6 {
            let phase = (Double(index) / 6 + t * 0.08).truncatingRemainder(dividingBy: 1)
            let depth = 0.2 + phase * 0.8
            let x = 180 + side * (48 + depth * 170)
            let y = 290 - depth * depth * 270
            ctx.setFillColor(NSColor(calibratedRed: 0.35, green: 0.24, blue: 0.15, alpha: 1).cgColor)
            ctx.fill(CGRect(x: x - depth * 5, y: y, width: depth * 10, height: depth * 90))
            ctx.setFillColor(NSColor(calibratedRed: 0.17, green: 0.38, blue: 0.24, alpha: 1).cgColor)
            ctx.fillEllipse(in: CGRect(x: x - depth * 35, y: y + depth * 55, width: depth * 70, height: depth * 85))
        }
    }
    ctx.restoreGState()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.white,
        .backgroundColor: NSColor.black.withAlphaComponent(0.65)]
    ("SYNTHETIC WALKING POV" as NSString).draw(at: CGPoint(x: 18, y: 600), withAttributes: attributes)
    (String(format: "TEST REPLAY  %02d:%02d", Int(t) / 60, Int(t) % 60) as NSString).draw(at: CGPoint(x: 18, y: 20), withAttributes: attributes)
    NSGraphicsContext.restoreGraphicsState()
    CVPixelBufferUnlockBaseAddress(buffer, [])
    guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: fps)) else { fatalError("Could not encode frame") }
}
input.markAsFinished()
let finished = DispatchSemaphore(value: 0)
writer.finishWriting { finished.signal() }
finished.wait()
guard writer.status == .completed else { fatalError("Video encoding failed") }
print("Generated 15-second HEVC synthetic POV clip at \(output)")
