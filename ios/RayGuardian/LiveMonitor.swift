import AVFoundation
import CoreMedia
import Foundation
import MWDATCamera
import MWDATCore
import Observation
import UIKit

@MainActor @Observable
final class LiveMonitor {
    var useAudio = false
    var useVision = false
    private(set) var registered = false
    private(set) var status: String
    private(set) var audioStatus = "Glasses microphone off"
    private(set) var analysis = "Nemotron off"
    private(set) var preview: UIImage?
    private(set) var remaining: Int?
    private(set) var incident: String?
    private(set) var receipt: String?
    private(set) var preparing = false
    private(set) var running = false
    private(set) var dispatchInProgress = false
    private(set) var canRetry = false

    let configured: Bool
    private let backend = Backend()
    @ObservationIgnored private lazy var selector = AutoDeviceSelector(wearables: Wearables.shared)
    private let tokens = ListenerTokenBag()
    private let speaker = AVSpeechSynthesizer()
    private let clock = ContinuousClock()
    private var foreground = false
    private var session: DeviceSession?
    private var camera: Camera?
    private var permissionTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?
    private var errorTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var checkIn: Task<Void, Never>?
    private var dispatchTask: Task<Void, Never>?
    private var startedAt: ContinuousClock.Instant?
    private var lastFrame: ContinuousClock.Instant?
    private var lastAudio: ContinuousClock.Instant?
    private var nextAnalysis: ContinuousClock.Instant?
    private var nextAudioCue: ContinuousClock.Instant?
    private var sessionID: UUID?
    private var pending: (id: UUID, trigger: String, context: String?)?
    private var recentFrames: [String] = []
    private var streamHasStarted = false
    var backendConfigured: Bool { backend.configured }

    init(setupError: String? = nil) {
        configured = setupError == nil
        status = setupError ?? "Pair your glasses in Meta AI, then connect Ray Guardian."
    }

    func observeRegistration() async {
        guard configured else { return }
        _ = selector
        for await state in Wearables.shared.registrationStateStream() {
            registered = state == .registered
            if registered && !running && !preparing { status = "Connected to Meta AI." }
            if !registered && running { stop("Meta AI registration ended.") }
        }
    }

    func register() {
        Task {
            do { try await Wearables.shared.startRegistration() }
            catch { status = error.localizedDescription }
        }
    }

    func handle(url: URL) {
        guard configured, URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true else { return }
        Task {
            do { _ = try await Wearables.shared.handleUrl(url) }
            catch { status = error.localizedDescription }
        }
    }

    func setForeground(_ active: Bool) {
        foreground = active
        if !active && running {
            stop("Live monitoring stopped when Ray Guardian left the foreground.")
            cancelCheckIn(speak: false)
            speaker.stopSpeaking(at: .immediate)
        }
    }

    func start() {
        guard configured, registered, foreground, !running, !preparing else { return }
        preparing = true
        let audio = useAudio
        let vision = useVision && backendConfigured
        permissionTask = Task {
            defer { preparing = false }
            do {
                let permissions: [Permission] = audio ? [.camera, .microphone] : [.camera]
                for permission in permissions {
                    status = "Checking glasses permissions. Meta AI may open to ask for access."
                    if try await Wearables.shared.checkPermissionStatus(permission) != .granted {
                        guard try await Wearables.shared.requestPermission(permission) == .granted else {
                            status = "The requested glasses permission was declined."
                            return
                        }
                        status = "Permission granted. Tap Start live monitoring to continue."
                        return
                    }
                }
                guard foreground, !Task.isCancelled else { return }
                try startSession(audio: audio, vision: vision)
            } catch {
                guard !Task.isCancelled else { return }
                stop(error.localizedDescription)
            }
        }
    }

    private func startSession(audio: Bool, vision: Bool) throws {
        let session = try Wearables.shared.createSession(deviceSelector: selector)
        self.session = session
        let id = UUID()
        sessionID = id
        running = true
        UIApplication.shared.isIdleTimerDisabled = true
        status = "Starting glasses session…"
        audioStatus = audio ? "Waiting for glasses microphone…" : "Glasses microphone off"
        analysis = vision ? "Waiting for camera samples…" : "Nemotron off"
        startedAt = clock.now
        stateTask = Task { [weak self] in
            for await state in session.stateStream() {
                guard let self, self.sessionID == id else { return }
                switch state {
                case .started where self.camera == nil:
                    do { try self.attachCamera(session, id: id, audio: audio, vision: vision) }
                    catch { self.stop(error.localizedDescription) }
                case .paused, .stopped:
                    self.stop("Glasses session \(state). Restart when available.")
                default: break
                }
            }
        }
        errorTask = Task { [weak self] in
            for await error in session.errorStream() {
                guard let self, self.sessionID == id else { return }
                self.stop(error.localizedDescription)
            }
        }
        try session.start()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.sessionID == id, let start = self.startedAt else { return }
                let now = self.clock.now
                if start.duration(to: now) >= .seconds(120) {
                    self.stop("Two-minute live session ended. Restart when ready.")
                } else if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                    self.stop("iPhone is too warm. Let it cool before restarting.")
                } else if now - (self.lastFrame ?? start) > .seconds(self.lastFrame == nil ? 20 : 6) {
                    self.stop("No recent camera images. Check the glasses connection.")
                } else if audio && now - (self.lastAudio ?? start) > .seconds(8) {
                    self.audioStatus = "No audio frames. Check Audio Streaming approval and microphone permission."
                }
            }
        }
    }

    private func attachCamera(_ session: DeviceSession, id: UUID, audio: Bool, vision: Bool) throws {
        let config = StreamConfiguration(
            videoCodec: .raw,
            audioCodec: audio ? .pcm(sampleRate: .rate16000, numberOfChannels: 1) : nil,
            resolution: .low,
            frameRate: 7
        )
        guard let camera = try session.addCamera(config: config) else {
            stop("Could not start the glasses camera.")
            return
        }
        self.camera = camera
        let stream = camera.stream
        let sampler = FrameSampler(encode: vision)
        let meter = SoundMeter()
        stream.videoFramePublisher.listen { [weak self] frame in
            guard let sample = sampler.sample(frame) else { return }
            Task { @MainActor in
                guard self?.sessionID == id else { return }
                self?.receive(image: sample.image, encoded: sample.encoded)
            }
        }.store(in: tokens)
        if audio {
            stream.audioFramePublisher.listen { [weak self] frame in
                guard let level = meter.read(frame.pcmBuffer, timestamp: frame.presentationTimeStamp) else { return }
                Task { @MainActor in
                    guard let self, self.sessionID == id else { return }
                    let now = self.clock.now
                    self.lastAudio = now
                    self.audioStatus = "Glasses microphone · \(level.dbfs) dBFS"
                    if level.sustained && (self.nextAudioCue.map { now >= $0 } ?? true) {
                        self.beginCheckIn(trigger: "loud-sound", context: "Sustained loud sound from glasses microphone.")
                    }
                }
            }.store(in: tokens)
        }
        stream.statePublisher.listen { [weak self] state in
            Task { @MainActor in
                guard let self, self.sessionID == id else { return }
                switch state {
                case .streaming: self.streamHasStarted = true
                case .paused: self.stop("Glasses camera paused.")
                case .stopped where self.streamHasStarted: self.stop("Glasses camera stopped.")
                default: break
                }
            }
        }.store(in: tokens)
        stream.errorPublisher.listen { [weak self] error in
            Task { @MainActor in
                guard self?.sessionID == id else { return }
                self?.stop(error.localizedDescription)
            }
        }.store(in: tokens)
        stream.start()
    }

    private func receive(image: UIImage, encoded: String?) {
        let now = clock.now
        lastFrame = now
        status = "Live camera · foreground monitoring"
        preview = image
        guard let encoded, checkIn == nil, pending == nil else { return }
        if recentFrames.count == 3 { recentFrames.removeFirst() }
        recentFrames.append(encoded)
        guard analysisTask == nil, recentFrames.count == 3,
              nextAnalysis.map({ now >= $0 }) ?? true, let id = sessionID else { return }
        let frames = recentFrames
        recentFrames.removeAll(keepingCapacity: true)
        nextAnalysis = now.advanced(by: .seconds(8))
        analysisTask = Task {
            defer { if sessionID == id { analysisTask = nil } }
            analysis = "Nemotron examining 3 live frames…"
            do {
                let result = try await backend.assess(frames)
                guard !Task.isCancelled, sessionID == id else { return }
                analysis = result.summary
                if result.checkInRecommended { beginCheckIn(trigger: "live-vision", context: result.summary) }
            } catch {
                if !Task.isCancelled && sessionID == id { analysis = error.localizedDescription }
            }
        }
    }

    private func beginCheckIn(trigger: String, context: String) {
        guard foreground, running, checkIn == nil, pending == nil else { return }
        let expires = clock.now.advanced(by: .seconds(15))
        remaining = 15
        say("Are you okay? Tap I'm okay to cancel the test call.")
        checkIn = Task {
            while !Task.isCancelled {
                let time = clock.now.duration(to: expires)
                if time <= .zero { break }
                let seconds = Int(time.components.seconds) + 1
                remaining = seconds
                incident = "Are you okay? Test call in \(seconds) s. \(context)"
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
            checkIn = nil
            remaining = nil
            pending = (UUID(), trigger, context)
            retryDispatch()
        }
    }

    func cancelCheckIn(speak: Bool = true) {
        guard checkIn != nil else { return }
        checkIn?.cancel()
        checkIn = nil
        remaining = nil
        recentFrames.removeAll()
        nextAnalysis = clock.now.advanced(by: .seconds(8))
        nextAudioCue = nextAnalysis
        incident = "Check-in cancelled."
        if speak { say("Check-in cancelled.") }
    }

    func manualSOS() {
        guard pending == nil else { return }
        cancelCheckIn(speak: false)
        pending = (UUID(), "manual-sos", nil)
        retryDispatch()
    }

    func retryDispatch() {
        guard let pending, !dispatchInProgress, foreground else { return }
        dispatchInProgress = true
        canRetry = false
        incident = "Sending to test dispatch…"
        dispatchTask = Task {
            defer { dispatchInProgress = false }
            do {
                let reply = try await backend.dispatch(id: pending.id, trigger: pending.trigger, context: pending.context)
                receipt = "Simulated call accepted · \(reply.callId)\nTest location: \(reply.location)"
                incident = "Test dispatch accepted the alert."
                self.pending = nil
                nextAnalysis = clock.now.advanced(by: .seconds(12))
                nextAudioCue = nextAnalysis
                say("Test dispatch accepted the alert.")
            } catch {
                receipt = error.localizedDescription
                canRetry = true
            }
        }
    }

    func stop(_ message: String = "Monitoring stopped.") {
        permissionTask?.cancel()
        permissionTask = nil
        preparing = false
        sessionID = nil
        stateTask?.cancel()
        errorTask?.cancel()
        watchdog?.cancel()
        analysisTask?.cancel()
        analysisTask = nil
        tokens.clear()
        if let camera { Task { await camera.stop() } }
        session?.stop()
        camera = nil
        session = nil
        lastFrame = nil
        lastAudio = nil
        recentFrames.removeAll()
        streamHasStarted = false
        running = false
        preview = nil
        status = message
        audioStatus = "Glasses microphone off"
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func say(_ text: String) {
        speaker.stopSpeaking(at: .immediate)
        speaker.speak(AVSpeechUtterance(string: text))
    }
}

private final class FrameSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var last = CMTime.invalid
    private let encode: Bool

    init(encode: Bool) { self.encode = encode }

    func sample(_ frame: VideoFrame) -> (image: UIImage, encoded: String?)? {
        lock.lock()
        defer { lock.unlock() }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(frame.sampleBuffer)
        if last.isValid, timestamp >= last, CMTimeGetSeconds(timestamp - last) < 1 { return nil }
        guard let image = frame.makeUIImage() else { return nil }
        last = timestamp
        guard encode else { return (image, nil) }
        let factor = min(1, 480 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * factor, height: image.size.height * factor)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return (image, scaled.jpegData(compressionQuality: 0.65).map { "data:image/jpeg;base64," + $0.base64EncodedString() })
    }
}

private final class SoundMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastEnd = CMTime.invalid
    private var loudSeconds = 0.0
    private var lastUpdate = CMTime.invalid

    func read(_ pcm: AVAudioPCMBuffer, timestamp: CMTime) -> (dbfs: Int, sustained: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        let count = Int(pcm.frameLength)
        guard count > 0 else { return nil }
        var squares = 0.0
        if let samples = pcm.int16ChannelData?[0] {
            for index in 0..<count { let sample = Double(samples[index]) / 32768; squares += sample * sample }
        } else if let samples = pcm.floatChannelData?[0] {
            for index in 0..<count { let sample = Double(samples[index]); squares += sample * sample }
        } else { return nil }
        let rms = sqrt(squares / Double(count))
        let level = rms.isFinite && rms > 0 ? Int(max(-96, min(0, 20 * log10(rms)))) : -96
        let duration = Double(count) / 16_000
        let contiguous = lastEnd.isValid && abs(CMTimeGetSeconds(timestamp - lastEnd)) < 0.15
        lastEnd = timestamp + CMTime(seconds: duration, preferredTimescale: 16_000)
        loudSeconds = level >= -18 ? (contiguous ? loudSeconds : 0) + duration : 0
        if lastUpdate.isValid && timestamp >= lastUpdate && CMTimeGetSeconds(timestamp - lastUpdate) < 0.4 && loudSeconds < 1 {
            return nil
        }
        lastUpdate = timestamp
        return (level, loudSeconds >= 1)
    }
}
