// Local-only conversion for MockDeviceKit: HEVC MP4, upright pixels, <=640px, 15fps, no audio.
// The output may be private. Store it under ignored captures/, never in app assets.
import AVFoundation
import Foundation

guard CommandLine.arguments.count >= 3 else { fatalError("Usage: swift prepare_pov_video.swift input.mov captures/replay.mp4 [h264]") }
let source = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
let track = source.tracks(withMediaType: .video).first!
let duration = source.duration
let composition = AVMutableComposition()
let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
try video.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
let bounds = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform).standardized
let scale = min(1, 640 / max(bounds.width, bounds.height))
let size = CGSize(width: max(2, floor(bounds.width * scale / 2) * 2), height: max(2, floor(bounds.height * scale / 2) * 2))
let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
layer.setTransform(track.preferredTransform
    .concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
    .concatenating(CGAffineTransform(scaleX: scale, y: scale)), at: .zero)
let instruction = AVMutableVideoCompositionInstruction()
instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
instruction.layerInstructions = [layer]
let render = AVMutableVideoComposition()
render.instructions = [instruction]
render.renderSize = size
render.frameDuration = CMTime(value: 1, timescale: 15)
try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
let browser = CommandLine.arguments.count > 3 && CommandLine.arguments[3] == "h264"
let export = AVAssetExportSession(asset: composition, presetName: browser ? AVAssetExportPreset1920x1080 : AVAssetExportPresetHEVC1920x1080)!
export.outputURL = destination
export.outputFileType = .mp4
export.videoComposition = render
export.shouldOptimizeForNetworkUse = true
let complete = DispatchSemaphore(value: 0)
export.exportAsynchronously { complete.signal() }
complete.wait()
guard export.status == .completed else { fatalError("Local conversion failed: \(export.error?.localizedDescription ?? "unknown error")") }
print("Prepared local replay (\(browser ? "browser H.264" : "HEVC")): \(Int(size.width))x\(Int(size.height)), 15fps, no audio, \(String(format: "%.1f", duration.seconds)) seconds")
