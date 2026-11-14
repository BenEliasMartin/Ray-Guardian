import Foundation
import UIKit
import Combine
import AVFoundation
import GuardianCore

@MainActor final class GuardianModel: ObservableObject {
    #if DEBUG
    @Published private(set) var debugLastCaptureFrames = 0
    var debugStopAfterFirstFrame = false
    #endif
    let settings = Settings(), glasses = GlassesAdapter(), phone = PhoneAudio(), voice = VoicePlayer(), replays = ReplayLibrary()
    let heartRate = HeartRateMonitor(), locator = IncidentLocation(), phoneMotion = PhoneMotion()
    private var phoneFall = FallCandidateDetector(), phoneMotionActive = false
    private var heartRateDetector = SustainedHeartRate(), located = Set<String>()
    @Published private(set) var session: GuardianSession?
    @Published private(set) var incident: Incident? {
        didSet {
            if armed, let incident, incident.state == "check_in", let deadline = incident.checkInDeadline {
                glasses.showCheckIn(id:incident.id,startedAt:Date(timeIntervalSince1970:incident.createdAt/1000),deadline:Date(timeIntervalSince1970:deadline/1000))
            } else {
                glasses.clearCheckIn()
            }
        }
    }
    @Published private(set) var detection: Detection?
    @Published private(set) var health: Health?
    @Published private(set) var armed = false
    @Published private(set) var capturing = false
    @Published private(set) var processing = false
    @Published private(set) var status = "Ready to configure"
    @Published private(set) var frameCount = 0
    @Published private(set) var audioSeconds = 0.0
    @Published private(set) var preview: UIImage?
    @Published private(set) var liveMockPreview = false
    @Published private(set) var starting = false
    @Published private(set) var lastEvidence = ""
    @Published var error: String?
    @Published private(set) var history: [Incident] = []
    private var api: GuardianAPI?, gate = PrivacyGate(), operation = UUID(), fall = FallCandidateDetector(), loudness = LoudnessDetector()
    private var captureTask: Task<Void,Never>?, replayAudioTask: Task<Void,Never>?, heartbeatTask: Task<Void,Never>?, uploadTask: Task<Void,Never>?, promptTask: Task<Void,Never>?
    private var candidates: [(time: Double, jpeg: Data, sharpness: Double)] = [], pcm: [Int16] = [], captureStart = 0.0, lastFrameAt = -10.0, activeCapture: UUID?
    /// The camera stays on while armed (live mock preview, or the opt-in pre-trigger buffer for real glasses).
    @Published private(set) var continuousCamera = false
    private var earlyCameraRequests = 0, earlyCameraTask: Task<Void,Error>?
    private var motionRecorder = MotionRecorder(), lastFallPattern: FallPattern?
    private var disarmTask: Task<Void,Never>?
    private var confirming = Set<String>()
    private var lastThreatAt: Double?
    private var lastDistressAt: Double?
    private var speechTask: Task<Void,Never>?
    private var speechBuffer = SpeechClipBuffer()
    private var pendingSpeech: [([Int16], Double)] = []
    /// In-memory only: at most the last three seconds, uploaded only inside an accepted capture window.
    private var recentPreviewFrames: [(time: Double, jpeg: Data, sharpness: Double)] = []
    @Published private(set) var cloudSpeechStatus = "Off"
    private var spoken = Set<String>(), relays = Set<AnyCancellable>(), isForeground = true
    init() {
        heartRate.onMeasurement = { [weak self] bpm in guard let self,self.armed,self.settings.heartRateEnabled else { return }; if self.heartRateDetector.consume(bpm:bpm,threshold:self.settings.heartRateThreshold,time:self.monotonic) { self.sendTrigger(.heart_rate) } }
        voice.$playing.sink { [weak self] playing in
            guard let self else { return }
            self.phone.setSuppressed(playing); self.glasses.setVoiceSuppressed(playing)
            if playing { self.speechBuffer = SpeechClipBuffer() }
        }.store(in:&relays)
        glasses.onFrame = { [weak self] in self?.receiveFrame($0) }
        glasses.onPCM = { [weak self] in self?.receivePCM($0,source: .glasses,arrivedAt:$1) }
        phone.onPCM = { [weak self] in self?.receivePCM($0,source: .phone,arrivedAt:$1) }
        phone.onFailure = { [weak self] message in self?.error = message; self?.stop() }
        glasses.onTranscript = { [weak self] in self?.receiveTranscript($0,final: $1,confidence: $2) }
        phone.onTranscript = { [weak self] in self?.receiveTranscript($0,final: $1,confidence: $2) }
        glasses.onMotion = { [weak self] point in
            guard let self,self.armed else { return }
            // While the iPhone stands in for the glasses IMU, its samples alone feed the motion summary.
            if !self.phoneMotionActive { self.motionRecorder.append(point.retimed(self.monotonic)) }
            if let pattern = self.fall.detect(point) { self.lastFallPattern = pattern; self.sendTrigger(.motion) }
        }
        phoneMotion.onMotion = { [weak self] point in
            guard let self,self.armed,self.phoneMotionActive else { return }
            self.motionRecorder.append(point.retimed(self.monotonic))
            if let pattern = self.phoneFall.detect(point) { self.lastFallPattern = pattern; self.sendTrigger(.motion_phone) }
        }
        phoneMotion.onFailure = { [weak self] message in self?.error = message; self?.stop() }
        glasses.onUnavailable = { [weak self] message in guard let self,self.armed || self.capturing else { return }; self.error = message; self.stop() }
        glasses.onDisplayCancel = { [weak self] id in
            guard let self, self.armed, self.isForeground, self.incident?.id == id, self.incident?.state == "check_in" else { return }
            self.cancelIncident()
        }
        settings.objectWillChange.sink { [weak self] _ in guard let self else { return }; if self.armed { self.stop() } }.store(in: &relays)
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification).sink { [weak self] _ in Task { @MainActor in guard let self,self.armed else { return }; self.error = "Audio interrupted; session stopped."; self.stop() } }.store(in: &relays)
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).sink { [weak self] note in
            guard let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt, reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            Task { @MainActor in guard let self,self.armed else { return }; self.error = "Audio device disconnected; session stopped."; self.stop() }
        }.store(in: &relays)
    }
    #if DEBUG
    func statusForUITesting() { status = "UI TEST FIXTURE · live providers disabled" }
    #endif
    func makeAPI() throws -> GuardianAPI { try GuardianAPI(url: settings.apiURL,token: settings.clientToken) }
    func checkBackend() async { do { try settings.save(); let client = try makeAPI(); health = try await client.get("health"); status = health?.ready == true ? "Backend and provider keys configured" : "Backend connected; provider keys still need configuration" } catch { self.error = error.localizedDescription } }
    func arm() async {
        guard !armed, !starting else { return }
        let token = UUID(); operation = token; starting = true; status = "Preparing local triggers"
        defer { if operation == token { starting = false } }
        do {
            guard !settings.consent.audio || settings.consent.cloud else { throw DeviceError.message("Audio sharing also requires cloud sharing consent.") }
            guard !settings.elevenLabsListening || (settings.consent.audio && settings.consent.cloud) else {
                throw DeviceError.message("ElevenLabs listening requires cloud analysis and audio sharing.")
            }
            guard settings.input != .real || settings.audio != .replay else { throw DeviceError.message("Choose a real microphone source for real-glasses mode.") }
            await disarmTask?.value; try checkOperation(token)
            try settings.save(); let client = try makeAPI(); api?.invalidate(); api = client
            if settings.input == .mock {
                #if DEBUG
                let clip = settings.mockUsesReplay ? replays.selected : nil
                let video = replays.url(clip?.video)
                if settings.mockUsesReplay, video == nil { throw DeviceError.message("Choose an available replay in Mock glasses, or switch to the live iPhone camera.") }
                if settings.consent.audio, settings.audio == .replay, replays.url(clip?.audio) == nil {
                    throw DeviceError.message("Choose the iPhone mic or a replay with a WAV track to include audio.")
                }
                try await glasses.prepareMock(video: video,motionCSV: replays.url(clip?.motion))
                #endif
            } else { await glasses.useReal() }
            try checkOperation(token)
            try await glasses.startStandby(useSpeech: settings.keywords == .glasses || settings.input == .mock); try checkOperation(token)
            if settings.keywords == .phone || settings.elevenLabsListening {
                let useLocalSpeech = settings.keywords == .phone
                try await phone.start(localASR: useLocalSpeech)
                try checkOperation(token)
            }
            #if DEBUG
            if settings.input == .mock, !settings.mockUsesReplay, settings.consent.capture {
                try await glasses.startCapture(includeGlassesAudio: settings.consent.audio && settings.audio == .glasses)
                try checkOperation(token)
                liveMockPreview = true; continuousCamera = true
            }
            #endif
            if !continuousCamera, settings.preTriggerFrames, settings.consent.capture, settings.consent.cloud {
                try await glasses.startCapture(includeGlassesAudio: settings.consent.audio && settings.audio == .glasses)
                try checkOperation(token)
                continuousCamera = true
            }
            let sceneChecks = settings.automaticSceneChecks && settings.consent.capture && settings.consent.cloud
            let phoneMotionTesting = settings.input == .mock && settings.phoneMotionTesting
            let created: GuardianSession = try await client.post("v1/sessions",body: CreateSession(consent: settings.consent,source: settings.input == .mock ? .meta_mock : .meta_glasses,automaticSceneChecks: sceneChecks,speechMonitoring: settings.elevenLabsListening,phoneMotionTesting: phoneMotionTesting)); try checkOperation(token)
            let active: GuardianSession = try await client.post("v1/sessions/\(created.id)/arm"); try checkOperation(token)
            let remaining = ((active.armedUntil ?? 0) / 1000) - Date().timeIntervalSince1970
            session = active
            guard active.armed, remaining > 0 else { throw DeviceError.message("The backend arming window expired.") }
            incident = nil; detection = nil; lastEvidence = ""; spoken.removeAll(); fall = FallCandidateDetector(); motionRecorder.reset(); lastFallPattern = nil; lastThreatAt = nil; lastDistressAt = nil
            cloudSpeechStatus = settings.elevenLabsListening ? "Listening on iPhone mic" : "Off"
            gate.arm(consent: settings.consent,now: monotonic,duration: remaining)
            armed = true; status = "Armed · up to 30 minutes"
            phoneFall = FallCandidateDetector()
            if phoneMotionTesting { try phoneMotion.start(); phoneMotionActive = true }
            heartbeatTask?.cancel(); heartbeatTask = Task { [weak self] in
                var nextSceneCheck = ProcessInfo.processInfo.systemUptime
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5)); guard let self,!Task.isCancelled,self.operation == token,self.armed else { return }
                    do {
                        let refreshed: GuardianSession = try await client.post("v1/sessions/\(active.id)/heartbeat"); guard self.operation == token else { return }
                        self.session = refreshed
                        if !refreshed.armed || (refreshed.armedUntil ?? 0) <= Date().timeIntervalSince1970*1000 { self.stop(); return }
                        await self.refreshIncident()
                        if sceneChecks, self.operation == token, self.isForeground, !self.capturing, !self.processing,
                           self.incident?.terminal != false, self.monotonic >= nextSceneCheck {
                            nextSceneCheck = self.monotonic + 20
                            self.sendTrigger(.scene_check)
                        }
                    } catch { guard self.operation == token else { return }; self.error = "Backend heartbeat lost: \(error.localizedDescription)"; self.stop(); return }
                }
            }
        } catch { guard operation == token else { return }; self.error = error.localizedDescription; stop() }
    }
    private var monotonic: Double { ProcessInfo.processInfo.systemUptime }
    private func checkOperation(_ token: UUID) throws { guard token == operation,isForeground,!Task.isCancelled else { throw CancellationError() } }
    func stop(cancelPending: Bool = true) {
        let oldSession = session, client = api
        operation = UUID(); gate.invalidate(); armed = false; starting = false; liveMockPreview = false; continuousCamera = false; capturing = false; processing = false; activeCapture = nil
        earlyCameraRequests = 0; earlyCameraTask?.cancel(); earlyCameraTask = nil; motionRecorder.reset(); lastFallPattern = nil
        captureTask?.cancel(); replayAudioTask?.cancel(); uploadTask?.cancel(); heartbeatTask?.cancel(); promptTask?.cancel()
        speechTask?.cancel(); speechTask = nil; speechBuffer = SpeechClipBuffer(); pendingSpeech.removeAll()
        recentPreviewFrames.removeAll(); cloudSpeechStatus = "Off"
        glasses.stop(); phone.stop(); phoneMotion.stop(); phoneMotionActive = false; voice.stop(); locator.cancel(); clearMedia(); status = "Disarmed · camera and local triggers off"
        if let id = oldSession?.id,let client { disarmTask = Task { [weak self] in
            do { struct Disarm: Encodable { let cancelPending: Bool }; let _: GuardianSession = try await client.post("v1/sessions/\(id)/disarm",body: Disarm(cancelPending: cancelPending)); if self?.session?.id == id { await self?.refreshIncident() } }
            catch { self?.error = "Stopped locally. Server cancellation was not confirmed: \(error.localizedDescription)" }
        } }
    }
    func sceneChanged(active: Bool) {
        isForeground = active
        if !active { stop(cancelPending: !(session?.consent.backgroundEscalation ?? false)) }
        else { Task { await refreshIncident(); await loadHistory() } }
    }
    func sendTrigger(_ signal: TriggerSignal) {
        guard armed,let session,let api else { return }; let token = operation, triggeredAt = monotonic
        // Start the camera now, in parallel with the server round trip, so the moments right after a fall are
        // not lost. Frames stay in memory and are discarded unless the server opens a capture window.
        let early = startEarlyCamera()
        Task { [weak self] in guard let self else { return }; do {
            let reply: TriggerReply = try await api.post("v1/sessions/\(session.id)/triggers",body: TriggerBody(signal)); try self.checkOperation(token)
            self.session = reply.session; self.incident = reply.incident ?? self.incident; self.shareLocationIfConsented(); self.status = reply.reason.replacingOccurrences(of: "_",with: " ")
            if let window = reply.window,!self.capturing,!self.processing { self.beginCapture(window,token: token,triggeredAt: triggeredAt,early: early) }
            else { self.endEarlyCamera(early); await self.handleVoice() }
        } catch { guard self.operation == token else { return }; self.endEarlyCamera(early); self.error = error.localizedDescription } }
    }
    private var glassesCaptureAudio: Bool { session?.consent.audio == true && settings.audio == .glasses }
    private func startEarlyCamera() -> Bool {
        guard !continuousCamera,!capturing,!processing,session?.consent.capture == true,session?.consent.cloud == true else { return false }
        earlyCameraRequests += 1
        if earlyCameraRequests == 1 {
            recentPreviewFrames.removeAll()
            let audio = glassesCaptureAudio
            earlyCameraTask = Task { [weak self] in guard let self else { return }; try await self.glasses.startCapture(includeGlassesAudio: audio) }
        }
        return true
    }
    private func endEarlyCamera(_ early: Bool) {
        guard early,earlyCameraRequests > 0 else { return }
        earlyCameraRequests -= 1
        guard earlyCameraRequests == 0,!capturing,!continuousCamera else { return }
        earlyCameraTask?.cancel(); earlyCameraTask = nil; glasses.stopCapture(); recentPreviewFrames.removeAll()
    }
    private func beginCapture(_ window: CaptureWindow,token: UUID,triggeredAt: Double,early: Bool) {
        guard let epoch = gate.beginCapture(now: monotonic) else { endEarlyCamera(early); return }
        let now = monotonic, start = max(triggeredAt,now-3)
        // Offsets are measured from the trigger itself; the capture never runs past eight seconds after it.
        let duration = min(8-(now-start),max(0,(window.captureEndsAt-Date().timeIntervalSince1970*1000)/1000))
        guard duration > 0 else { gate.endCapture(); endEarlyCamera(early); error = "Capture window expired before camera startup."; return }
        clearMedia(); capturing = true; activeCapture = epoch; captureStart = start; lastFrameAt = -10; status = "Capturing up to 8 seconds in memory"
        candidates = recentPreviewFrames.filter { start-$0.time <= 3 && $0.time <= now }
        if !continuousCamera { recentPreviewFrames.removeAll() }
        frameCount = min(KeyframeSelector.maximumFrames,candidates.count)
        let cameraAlreadyRequested = early && earlyCameraRequests > 0, pendingCamera = earlyCameraTask
        if early { earlyCameraRequests = max(0,earlyCameraRequests-1) }
        captureTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration)); guard let self,!Task.isCancelled,self.operation == token else { return }; self.finishCapture(window,token: token)
        }
        Task { [weak self] in guard let self else { return }; do {
            if !self.continuousCamera {
                var running = false
                if cameraAlreadyRequested,let pendingCamera { running = (try? await pendingCamera.value) != nil }
                if !running { try await self.glasses.startCapture(includeGlassesAudio: self.glassesCaptureAudio) }
            }
            try self.checkOperation(token)
            guard self.capturing,self.activeCapture == epoch else { if !self.continuousCamera { self.glasses.stopCapture() }; return }
            if self.session?.consent.audio == true {
                if self.settings.audio == .phone,self.settings.keywords != .phone,!self.settings.elevenLabsListening { try await self.phone.start(localASR: false); guard self.capturing,self.operation == token else { self.phone.stop(); return } }
                if self.settings.audio == .replay { try self.startReplayAudio(token: token) }
            }
        } catch { guard self.operation == token else { return }; self.error = error.localizedDescription; self.stop() } }
    }
    private func receiveFrame(_ image: UIImage) {
        let now = monotonic
        if liveMockPreview { preview = image }
        let captureFrame = capturing && now <= captureStart+8 && activeCapture.map { gate.accepts($0,now: now) } == true &&
            candidates.count < 40 && now - captureStart - lastFrameAt >= 0.3
        let bufferFrame = armed && (continuousCamera || earlyCameraRequests > 0) && settings.consent.capture && settings.consent.cloud &&
            (recentPreviewFrames.last.map { now - $0.time >= 0.4 } ?? true)
        guard captureFrame || bufferFrame else { return }
        let offset = now-captureStart
        let size = image.size, scale = min(1,640/max(size.width,size.height)), target = CGSize(width: size.width*scale,height: size.height*scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let reduced = UIGraphicsImageRenderer(size: target,format: format).image { _ in image.draw(in: CGRect(origin: .zero,size: target)) }
        var jpeg: Data?
        for quality: CGFloat in [0.65,0.45,0.25] { if let data = reduced.jpegData(compressionQuality: quality),data.count <= 131072 { jpeg = data; break } }
        guard let jpeg else { return }
        let sharpness = Self.sharpness(reduced)
        if bufferFrame {
            recentPreviewFrames.append((now,jpeg,sharpness))
            recentPreviewFrames.removeAll { now - $0.time > 3 }
        }
        guard captureFrame else { return }
        candidates.append((now,jpeg,sharpness)); frameCount = min(KeyframeSelector.maximumFrames,candidates.count); lastFrameAt = offset; preview = reduced
        #if DEBUG
        debugLastCaptureFrames = candidates.count
        if debugStopAfterFirstFrame { debugStopAfterFirstFrame = false; stop() }
        #endif
    }
    /// Laplacian variance of a small grayscale copy: blurred or dark frames score low.
    private static func sharpness(_ image: UIImage) -> Double {
        guard let cg = image.cgImage,cg.width > 0 else { return 0 }
        let width = 160, height = max(3,Int(Double(width)*Double(cg.height)/Double(cg.width)))
        var gray = [UInt8](repeating: 0,count: width*height)
        let drawn = gray.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress,width: width,height: height,bitsPerComponent: 8,bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(cg,in: CGRect(x: 0,y: 0,width: width,height: height)); return true
        }
        return drawn ? FrameSharpness.laplacianVariance(gray,width: width,height: height) : 0
    }
    private func receivePCM(_ samples: [Int16],source: AudioMode,arrivedAt:Double) {
        guard armed else { return }
        if voice.suppressInput { return }
        if source == .phone, settings.elevenLabsListening { monitorSpeech(samples) }
        if loudness.consume(samples,time: monotonic) { status = capturing ? "Loud audio during capture · evidence only" : "Loud audio detected locally · no capture triggered" }
        guard arrivedAt >= captureStart,arrivedAt <= captureStart+8,capturing,session?.consent.audio == true,settings.audio == source,let epoch = activeCapture,gate.accepts(epoch,now: monotonic) else { return }
        pcm.append(contentsOf: samples.prefix(max(0,128000-pcm.count))); audioSeconds = Double(pcm.count)/16000
    }
    private func monitorSpeech(_ samples: [Int16]) {
        for clip in speechBuffer.consume(samples) {
            if pendingSpeech.count >= 3 { pendingSpeech.removeFirst() }
            pendingSpeech.append((clip, monotonic))
        }
        submitNextSpeechClip()
    }
    private func submitNextSpeechClip() {
        guard speechTask == nil, armed, let api, let session else { return }
        let now = monotonic
        pendingSpeech.removeAll { now - $0.1 > 15 }
        guard !pendingSpeech.isEmpty else { return }
        let (clip, _) = pendingSpeech.removeFirst()
        struct Transcript: Decodable {
            let text: String
            let detection: Detection?
            let trigger: TriggerReply?
        }
        let token = operation
        cloudSpeechStatus = "Checking speech…"
        speechTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.operation == token {
                    self.speechTask = nil
                    self.submitNextSpeechClip()
                }
            }
            do {
                let body = AudioPayload(wav: PCM16WAV.encode(clip),source: "phone")
                let result: Transcript = try await api.post("v1/sessions/\(session.id)/speech",body: body)
                try self.checkOperation(token)
                self.receiveTranscript(result.text,final: true,confidence: -1,commandsOnly: true)
                try self.checkOperation(token)
                if let assessment = result.detection {
                    self.cloudSpeechStatus = assessment.source == "nemotron_unavailable"
                        ? "Speech assessment unavailable" : "Speech assessed by Nemotron"
                } else {
                    self.cloudSpeechStatus = result.text.isEmpty ? "No speech in last clip" : "Speech recognized"
                }
                if let trigger = result.trigger {
                    self.session = trigger.session
                    self.incident = trigger.incident ?? self.incident
                    self.detection = result.detection
                    self.lastEvidence = "Speech transcribed by ElevenLabs"
                    self.shareLocationIfConsented()
                    if let window = trigger.window, !self.capturing, !self.processing {
                        self.beginCapture(window,token: token,triggeredAt: self.monotonic,early: false)
                    }
                    await self.handleVoice()
                }
            } catch {
                guard self.operation == token else { return }
                self.cloudSpeechStatus = error.localizedDescription
            }
        }
    }
    private func receiveTranscript(_ text: String,final: Bool,confidence: Float,commandsOnly: Bool = false) {
        guard armed,!voice.suppressInput else { return }
        guard let intent = KeywordDetector.intent(text,isFinal: final,confidence: confidence,isPlayingVoice: voice.suppressInput) else { return }
        switch intent {
        case .cancel: cancelIncident()
        case .sos: sendTrigger(.keyword_sos)
        case .distress:
            guard !commandsOnly, !settings.elevenLabsListening else { return }
            guard lastDistressAt.map({ monotonic - $0 >= 30 }) ?? true else { return }
            lastDistressAt = monotonic
            sendTrigger(.keyword_distress)
        case .threat:
            guard !commandsOnly, !settings.elevenLabsListening else { return }
            guard lastThreatAt.map({ monotonic - $0 >= 30 }) ?? true else { return }
            lastThreatAt = monotonic
            sendTrigger(.spoken_threat)
        }
    }
    private func startReplayAudio(token: UUID) throws {
        guard let url = replays.url(replays.selected?.audio) else { throw DeviceError.message("No replay WAV selected. Prepare media or choose another audio input.") }
        let samples = try PCM16WAV.decode(Data(contentsOf: url))
        replayAudioTask = Task { [weak self] in
            for start in stride(from: 0,to: samples.count,by: 320) {
                guard !Task.isCancelled,let self,self.operation == token,self.capturing else { return }
                self.receivePCM(Array(samples[start..<min(start+320,samples.count)]),source: .replay,arrivedAt:self.monotonic)
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }
    private func finishCapture(_ window: CaptureWindow,token: UUID) {
        if !continuousCamera,earlyCameraRequests == 0 { glasses.stopCapture(); recentPreviewFrames.removeAll() }
        replayAudioTask?.cancel(); if settings.keywords != .phone && !settings.elevenLabsListening { phone.stop() }
        capturing = false; gate.endCapture(); activeCapture = nil
        guard let session,let api else { clearMedia(); return }
        let audio = pcm.count >= 1600 ? AudioPayload(wav: PCM16WAV.encode(pcm),source: settings.audio.rawValue) : nil
        let picked = KeyframeSelector.select(offsets: candidates.map { $0.time-captureStart },sharpness: candidates.map { $0.sharpness })
        let frames = picked.map { FramePayload(offsetMs: min(8000,max(-3000,((candidates[$0].time-captureStart)*1000).rounded())),jpeg: candidates[$0].jpeg) }
        let motion = motionRecorder.summary(triggerAt: captureStart,endAt: monotonic,fallPattern: [TriggerSignal.motion.rawValue,TriggerSignal.motion_phone.rawValue].contains(window.signal) ? lastFallPattern : nil)
        let payload = ObservationPayload(windowId: window.id,frames: frames,audio: audio,transcript: nil,source: session.source,motion: motion)
        let hasEvidence = !frames.isEmpty || audio != nil
        clearMedia(); guard hasEvidence else { error = "No usable frames or bounded microphone audio arrived in the capture window."; return }
        processing = true; status = "Transcribing audio and asking Nemotron to assess actual evidence"
        uploadTask = Task { [weak self] in guard let self else { return }; do {
            let result: ObservationResult = try await api.post("v1/sessions/\(session.id)/observations",body: payload); try self.checkOperation(token)
            self.processing = false; self.lastEvidence = "\(result.framesAnalyzed) frames analyzed · \(String(format: "%.1f",result.audioDurationMs/1000)) seconds of audio · transcription: \(result.audioTranscriptionSource ?? "none")"; self.detection = result.detection; self.incident = result.incident ?? self.incident; self.shareLocationIfConsented(); self.status = "\(result.detection.source): \(result.detection.label.replacingOccurrences(of: "_",with: " ")) · \(result.detection.confidence) confidence"; await self.handleVoice()
        } catch { guard self.operation == token else { return }; self.processing = false; self.error = error.localizedDescription } }
    }
    private func clearMedia() { candidates.removeAll(keepingCapacity: false); pcm.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }; pcm.removeAll(keepingCapacity: false); if !liveMockPreview { preview = nil }; frameCount = 0; audioSeconds = 0 }
    func refreshIncident() async {
        guard let id = session?.incidentId ?? incident?.id,let api else { return }; let epoch = operation
        do {
            let value: Incident = try await api.get("v1/incidents/\(id)")
            guard operation == epoch,(session?.incidentId ?? incident?.id) == id else { return }
            incident = value; detection = value.detection ?? detection
            // The server issues this challenge only AFTER the check-in deadline. A fresh foreground
            // round trip is required unless the wearer explicitly consented to background escalation.
            if value.state == "awaiting_foreground_confirmation",let token = value.escalationToken,armed,isForeground,!confirming.contains(id) {
                confirming.insert(id); defer { confirming.remove(id) }
                struct Confirmation: Encodable { let token:String }
                let confirmed: Incident = try await api.post("v1/incidents/\(id)/escalate",body:Confirmation(token:token))
                guard operation == epoch,armed,isForeground else { return }; incident = confirmed
            }
            await handleVoice()
        } catch { if operation == epoch { self.error = error.localizedDescription } }
    }
    private func handleVoice() async {
        guard isForeground,!capturing,!processing,let incident,incident.voiceConsent,settings.consent.voice,let api else { return }
        let key = incident.id+":"+incident.state
        guard !spoken.contains(key) else { return }
        let prompt: String?
        switch incident.state { case "check_in": prompt = "check_in"; case "cancelled": prompt = "cancelled"; case "acknowledged": prompt = "acknowledged"; case "demo_call_active": prompt = nil; default: return }
        spoken.insert(key); promptTask?.cancel()
        promptTask = Task { [weak self] in guard let self else { return }; do {
            let data: Data
            if let prompt { data = try await api.prompt(purpose: prompt,incidentId: incident.id,sessionId: nil) }
            else { data = try await api.audio("v1/demo-calls/\(incident.id)/audio") }
            guard !Task.isCancelled,self.isForeground,self.incident?.id == incident.id,self.incident?.state == incident.state else { return }
            if incident.state == "check_in",let deadline = incident.checkInDeadline,Date().timeIntervalSince1970*1000 >= deadline { await self.refreshIncident(); return }
            try self.voice.play(data)
        } catch { guard !Task.isCancelled else { return }; self.error = "ElevenLabs voice unavailable: \(error.localizedDescription)" } }
    }
    func cancelIncident() {
        let id = incident?.id, client = api
        // Cancellation also disarms, invalidating pending trigger replies and capture callbacks.
        stop(cancelPending:true)
        guard let id,let client else { return }
        Task { [weak self] in do {
            let value: Incident = try await client.post("v1/incidents/\(id)/cancel")
            guard self?.incident?.id == id else { return }; self?.incident = value; await self?.handleVoice()
        } catch { self?.error = "Cancellation not confirmed: \(error.localizedDescription)" } }
    }
    func acknowledge() async { guard let incident,let api else { return }; do { self.incident = try await api.post("v1/incidents/\(incident.id)/acknowledge"); voice.stop(); await handleVoice() } catch { self.error = error.localizedDescription } }
    private func shareLocationIfConsented() {
        guard let incident,session?.consent.location == true,!located.contains(incident.id),let api else { return }
        located.insert(incident.id); let token = operation
        Task { [weak self] in guard let self else { return }; do {
            let location = try await self.locator.current(); try self.checkOperation(token)
            struct Body: Encodable { let latitude:Double,longitude:Double,accuracyMeters:Double,timestamp:Double }
            let value: Incident = try await api.post("v1/incidents/\(incident.id)/location",body:Body(latitude:location.coordinate.latitude,longitude:location.coordinate.longitude,accuracyMeters:location.horizontalAccuracy,timestamp:location.timestamp.timeIntervalSince1970*1000))
            guard self.incident?.id == incident.id,self.operation == token else { return }; self.incident = value
        } catch { if self.operation == token { self.error = "Location was not shared: \(error.localizedDescription)" } } }
    }
    func replayMotion() { fall = FallCandidateDetector(); glasses.replayMotion() }
    func loadHistory() async { do { struct List: Decodable { let incidents: [Incident] }; let client = try makeAPI(); history = try await client.get("v1/incidents",as: List.self).incidents } catch { /* Configuration can be empty on first launch. */ } }
    func deleteIncident(_ item: Incident) async { do { let client = try makeAPI(); try await client.delete("v1/incidents/\(item.id)"); if incident?.id == item.id { incident = nil }; await loadHistory() } catch { self.error = error.localizedDescription } }
}
