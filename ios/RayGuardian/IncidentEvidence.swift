import AVFoundation
import CryptoKit
import ImageIO
import GuardianCore
import Security

struct IncidentFrame: Sendable {
    let time: Double
    let jpeg: Data
    let sharpness: Double
}

struct IncidentClipAudio: Sendable {
    static let sampleRate = 16_000
    private static let maximumSamples = 8 * sampleRate
    let start: Double
    private(set) var samples: [Int16] = []

    mutating func append(_ incoming: [Int16], endingAt end: Double) {
        let offset = Int(((end - start) * Double(Self.sampleRate)).rounded()) - incoming.count
        let destination = max(0, offset, samples.count)
        let skip = destination - offset
        let count = min(incoming.count - skip, Self.maximumSamples - destination)
        guard count > 0 else { return }
        if destination > samples.count {
            samples.append(contentsOf: repeatElement(0, count: destination - samples.count))
        }
        samples.append(contentsOf: incoming[skip..<(skip + count)])
    }
}

enum ReviewedEvidence: Sendable {
    case clip(URL)
    case photo(Data, verified: Bool)
    case integrityFailed
    case unavailable
}

actor IncidentEvidence {
    private enum Kind: String, Codable {
        case clip = "mp4"
        case photo = "jpg"
    }

    private struct Manifest: Codable {
        let version: Int
        let incidentID: UUID
        let createdAt: Date
        let kind: Kind
        let digest: Data
    }

    private struct Seal: Codable {
        let manifest: Data
        let signature: Data
    }

    private enum EvidenceError: Error { case signingKeyUnavailable, videoEncodingFailed }

    private static let retention: TimeInterval = 24 * 60 * 60
    private let files = FileManager.default
    private let root: URL
    private let legacy: URL

    init(applicationSupport: URL = .applicationSupportDirectory) {
        root = applicationSupport.appending(path: "IncidentEvidence", directoryHint: .isDirectory)
        legacy = applicationSupport.appending(path: "IncidentPhotos", directoryHint: .isDirectory)
    }

    func save(_ frames: [IncidentFrame], audio: IncidentClipAudio? = nil, id: UUID, createdAt: Date) async throws {
        guard Date().timeIntervalSince(createdAt) < Self.retention,
              let best = frames.max(by: { $0.sharpness < $1.sharpness }) else { return }
        let destination = evidenceFolder(id)
        guard !files.fileExists(atPath: destination.path) else { return }

        try prepareRoot()
        let staging = root.appending(path: ".pending-" + UUID().uuidString, directoryHint: .isDirectory)
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staging) }

        var kind = Kind.photo
        let video = mediaURL(.clip, in: staging)
        if frames.count >= 3, let first = frames.first, let last = frames.last, last.time - first.time >= 0.5 {
            do {
                try await encode(frames, at: video)
                if let audio, !audio.samples.isEmpty, let first = frames.first {
                    try await addAudio(audio, videoStart: first.time, to: video)
                }
                kind = .clip
            } catch {
                try Task.checkCancellation()
                try? files.removeItem(at: video)
            }
        }
        let media = mediaURL(kind, in: staging)
        if kind == .photo { try best.jpeg.write(to: media, options: .atomic) }

        let bytes = try Data(contentsOf: media, options: .mappedIfSafe)
        let manifest = Manifest(version: 1, incidentID: id, createdAt: createdAt, kind: kind,
                                digest: Data(SHA256.hash(data: bytes)))
        let encoded = try JSONEncoder().encode(manifest)
        let signature = try signingKey(createIfNeeded: true).signature(for: encoded)
        let seal = try JSONEncoder().encode(Seal(manifest: encoded, signature: signature))
        let sealURL = staging.appending(path: "seal.json")
        try seal.write(to: sealURL, options: .atomic)
        #if os(iOS)
        for url in [media, sealURL] {
            try files.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        }
        #endif
        try files.setAttributes([.modificationDate: createdAt], ofItemAtPath: staging.path)

        try Task.checkCancellation()
        guard Date().timeIntervalSince(createdAt) < Self.retention,
              !files.fileExists(atPath: destination.path) else { return }
        try files.moveItem(at: staging, to: destination)
    }

    func review(id: UUID, createdAt: Date) -> ReviewedEvidence {
        guard Date().timeIntervalSince(createdAt) < Self.retention else { return .unavailable }
        let folder = evidenceFolder(id)
        guard files.fileExists(atPath: folder.path) else {
            return (try? Data(contentsOf: legacyPhoto(id))).map { .photo($0, verified: false) } ?? .unavailable
        }
        do {
            let sealBytes = try Data(contentsOf: folder.appending(path: "seal.json"))
            let seal = try JSONDecoder().decode(Seal.self, from: sealBytes)
            let publicKey = try signingKey(createIfNeeded: false).publicKey
            guard publicKey.isValidSignature(seal.signature, for: seal.manifest) else { return .integrityFailed }
            let manifest = try JSONDecoder().decode(Manifest.self, from: seal.manifest)
            guard manifest.version == 1, manifest.incidentID == id, manifest.createdAt == createdAt else {
                return .integrityFailed
            }
            let url = mediaURL(manifest.kind, in: folder)
            let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
            guard Data(SHA256.hash(data: bytes)) == manifest.digest else { return .integrityFailed }
            return manifest.kind == .clip ? .clip(url) : .photo(bytes, verified: true)
        } catch {
            return .integrityFailed
        }
    }

    func delete(id: UUID) throws {
        for url in [evidenceFolder(id), legacyPhoto(id)] {
            do { try files.removeItem(at: url) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { }
        }
    }

    func removeExpired() {
        let cutoff = Date().addingTimeInterval(-Self.retention)
        for directory in [root, legacy] {
            let items = try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            for item in items ?? [] {
                if let updated = try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   updated <= cutoff {
                    try? files.removeItem(at: item)
                }
            }
        }
    }

    private func evidenceFolder(_ id: UUID) -> URL { root.appending(path: id.uuidString, directoryHint: .isDirectory) }
    private func legacyPhoto(_ id: UUID) -> URL { legacy.appending(path: id.uuidString + ".jpg") }

    private func mediaURL(_ kind: Kind, in folder: URL) -> URL {
        folder.appending(path: "evidence." + kind.rawValue)
    }

    private func prepareRoot() throws {
        #if os(iOS)
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
        #else
        let attributes: [FileAttributeKey: Any] = [:]
        #endif
        try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: attributes)
        var directory = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }

    private func signingKey(createIfNeeded: Bool) throws -> Curve25519.Signing.PrivateKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.rayguardian.incident-evidence",
            kSecAttrAccount as String: "signing-key-v1"
        ]
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &value)
        if status == errSecSuccess, let bytes = value as? Data {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: bytes)
        }
        guard status == errSecItemNotFound, createIfNeeded else { throw EvidenceError.signingKeyUnavailable }
        let key = Curve25519.Signing.PrivateKey()
        var attributes = query
        attributes[kSecValueData as String] = key.rawRepresentation
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(attributes as CFDictionary, nil)
        if added == errSecDuplicateItem { return try signingKey(createIfNeeded: false) }
        guard added == errSecSuccess else { throw EvidenceError.signingKeyUnavailable }
        return key
    }

    private func encode(_ frames: [IncidentFrame], at url: URL) async throws {
        guard let first = frames.first, let image = decode(first.jpeg) else {
            throw EvidenceError.videoEncodingFailed
        }
        let width = max(2, image.width & ~1)
        let height = max(2, image.height & ~1)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        guard writer.canAdd(input) else { throw EvidenceError.videoEncodingFailed }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? EvidenceError.videoEncodingFailed }
        defer { if writer.status == .writing { writer.cancelWriting() } }
        writer.startSession(atSourceTime: .zero)

        let deadline = ContinuousClock.now + .seconds(5)
        var last = CMTime.invalid
        var written = 0
        for frame in frames {
            try Task.checkCancellation()
            let time = CMTime(seconds: frame.time - first.time, preferredTimescale: 600)
            guard !last.isValid || time > last, let image = decode(frame.jpeg) else { continue }
            try await waitUntilReady(input, writer: writer, deadline: deadline)
            guard let pool = adaptor.pixelBufferPool,
                  let buffer = pixelBuffer(for: image, pool: pool, width: width, height: height),
                  adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? EvidenceError.videoEncodingFailed
            }
            last = time
            written += 1
        }
        guard written >= 3, last.seconds >= 0.5 else { throw EvidenceError.videoEncodingFailed }
        let end = last + CMTime(seconds: 0.18, preferredTimescale: 600)
        writer.endSession(atSourceTime: end)
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? EvidenceError.videoEncodingFailed }
    }

    private func waitUntilReady(_ input: AVAssetWriterInput, writer: AVAssetWriter,
                                deadline: ContinuousClock.Instant) async throws {
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing, ContinuousClock.now < deadline else {
                throw writer.error ?? EvidenceError.videoEncodingFailed
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func addAudio(_ audio: IncidentClipAudio, videoStart: Double, to video: URL) async throws {
        let rate = Double(IncidentClipAudio.sampleRate)
        let offset = audio.start - videoStart
        let trim = max(0, Int((-offset * rate).rounded(.up)))
        guard trim < audio.samples.count else { return }

        let folder = video.deletingLastPathComponent()
        let wav = folder.appending(path: "audio.wav")
        let combined = folder.appending(path: "combined.mp4")
        defer {
            try? files.removeItem(at: wav)
            try? files.removeItem(at: combined)
        }
        do {
            try PCM16WAV.encode(Array(audio.samples.dropFirst(trim))).write(to: wav, options: .atomic)
            let videoAsset = AVURLAsset(url: video)
            let audioAsset = AVURLAsset(url: wav)
            let composition = AVMutableComposition()
            let duration = try await videoAsset.load(.duration)
            let audioStart = CMTime(seconds: max(0, offset), preferredTimescale: Int32(rate))
            guard audioStart < duration,
                  let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
                  let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first,
                  let picture = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                  let sound = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return }

            let audioDuration = min(try await audioAsset.load(.duration), duration - audioStart)
            guard audioDuration > .zero else { return }
            try picture.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: videoTrack, at: .zero)
            try sound.insertTimeRange(CMTimeRange(start: .zero, duration: audioDuration), of: audioTrack, at: audioStart)
            guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality),
                  exporter.supportedFileTypes.contains(.mp4) else { throw EvidenceError.videoEncodingFailed }
            exporter.outputURL = combined
            exporter.outputFileType = .mp4
            await withTaskCancellationHandler {
                await exporter.export()
            } onCancel: {
                exporter.cancelExport()
            }
            try Task.checkCancellation()
            guard exporter.status == .completed else { throw exporter.error ?? EvidenceError.videoEncodingFailed }
            let output = AVURLAsset(url: combined)
            guard try await !output.loadTracks(withMediaType: .audio).isEmpty else { throw EvidenceError.videoEncodingFailed }
            _ = try files.replaceItemAt(video, withItemAt: combined)
        } catch {
            // Keep the original video if the microphone track could not be encoded.
            try Task.checkCancellation()
        }
    }

    private func decode(_ jpeg: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func pixelBuffer(for image: CGImage, pool: CVPixelBufferPool, width: Int, height: Int) -> CVPixelBuffer? {
        var result: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &result) == kCVReturnSuccess, let buffer = result else { return nil }
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
