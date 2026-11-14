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
    let heartRate = HeartRateMonitor(), locator = IncidentLocation()
    private var heartRateDetector = SustainedHeartRate(), located = Set<String>()
    @Published private(set) var session: GuardianSession?
    @Published private(set) var incident: Incident?
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
    private var frames: [FramePayload] = [], pcm: [Int16] = [], captureStart = 0.0, lastFrameAt = -10.0, activeCapture: UUID?
    private var disarmTask: Task<Void,Never>?
    private var confirming = Set<String>()
    private var lastThreatAt: Double?
    private var lastDistressAt: Double?
    private var speechTask: Task<Void,Never>?
    private var speechPCM: [Int16] = []
    private var speechHasSound = false
    private var recentPreviewFrames: [(time: Double, jpeg: Data)] = []
    @Published private(set) var cloudSpeechStatus = "Off"
    private var spoken = Set<String>(), relays = Set<AnyCancellable>(), isForeground = true
    init() {
        heartRate.onMeasurement = { [weak self] bpm in guard let self,self.armed,self.settings.heartRateEnabled else { return }; if self.heartRateDetector.consume(bpm:bpm,threshold:self.settings.heartRateThreshold,time:self.monotonic) { self.sendTrigger(.heart_rate) } }
        voice.$playing.sink { [weak self] playing in self?.phone.setSuppressed(playing); self?.glasses.setVoiceSuppressed(playing) }.store(in:&relays)
        glasses.onFrame = { [weak self] in self?.receiveFrame($0) }
        glasses.onPCM = { [weak self] in self?.receivePCM($0,source: .glasses,arrivedAt:$1) }
        phone.onPCM = { [weak self] in self?.receivePCM($0,source: .phone,arrivedAt:$1) }
        phone.onFailure = { [weak self] message in self?.error = message; self?.stop() }
        glasses.onTranscript = { [weak self] in self?.receiveTranscript($0,final: $1,confidence: $2) }
        phone.onTranscript = { [weak self] in self?.receiveTranscript($0,final: $1,confidence: $2) }
        glasses.onMotion = { [weak self] point in guard let self,self.armed else { return }; if self.fall.consume(point) { self.sendTrigger(.motion) } }
        glasses.onUnavailable = { [weak self] message in guard let self,self.armed || self.capturing else { return }; self.error = message; self.stop() }
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
                let useLocalSpeech = settings.keywords == .phone && !settings.elevenLabsListening
                try await phone.start(localASR: useLocalSpeech)
                try checkOperation(token)
            }
            #if DEBUG
            if settings.input == .mock, !settings.mockUsesReplay, settings.consent.capture {
                try await glasses.startCapture(includeGlassesAudio: settings.consent.audio && settings.audio == .glasses)
                try checkOperation(token)
                liveMockPreview = true
            }
            #endif
            let sceneChecks = settings.automaticSceneChecks && settings.consent.capture && settings.consent.cloud
            let created: GuardianSession = try await client.post("v1/sessions",body: CreateSession(consent: settings.consent,source: settings.input == .mock ? .meta_mock : .meta_glasses,automaticSceneChecks: sceneChecks,speechMonitoring: settings.elevenLabsListening)); try checkOperation(token)
            let active: GuardianSession = try await client.post("v1/sessions/\(created.id)/arm"); try checkOperation(token)
            let remaining = ((active.armedUntil ?? 0) / 1000) - Date().timeIntervalSince1970
            session = active
            guard active.armed, remaining > 0 else { throw DeviceError.message("The backend arming window expired.") }
            incident = nil; detection = nil; lastEvidence = ""; spoken.removeAll(); fall = FallCandidateDetector(); lastThreatAt = nil; lastDistressAt = nil
            cloudSpeechStatus = settings.elevenLabsListening ? "Listening on iPhone mic" : "Off"
            gate.arm(consent: settings.consent,now: monotonic,duration: remaining)
            armed = true; status = "Armed · up to 30 minutes"
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
        operation = UUID(); gate.invalidate(); armed = false; starting = false; liveMockPreview = false; capturing = false; processing = false; activeCapture = nil
        captureTask?.cancel(); replayAudioTask?.cancel(); uploadTask?.cancel(); heartbeatTask?.cancel(); promptTask?.cancel()
        speechTask?.cancel(); speechTask = nil; speechPCM.removeAll(); speechHasSound = false
        recentPreviewFrames.removeAll(); cloudSpeechStatus = "Off"
        glasses.stop(); phone.stop(); voice.stop(); locator.cancel(); clearMedia(); status = "Disarmed · camera and local triggers off"
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
        guard armed,let session,let api else { return }; let token = operation
        Task { [weak self] in guard let self else { return }; do {
            let reply: TriggerReply = try await api.post("v1/sessions/\(session.id)/triggers",body: TriggerBody(signal)); try self.checkOperation(token)
            self.session = reply.session; self.incident = reply.incident ?? self.incident; self.shareLocationIfConsented(); self.status = reply.reason.replacingOccurrences(of: "_",with: " ")
            if let window = reply.window,!self.capturing,!self.processing { self.beginCapture(window,token: token) }
            else { await self.handleVoice() }
        } catch { guard self.operation == token else { return }; self.error = error.localizedDescription } }
    }
    private func beginCapture(_ window: CaptureWindow,token: UUID) {
        guard let epoch = gate.beginCapture(now: monotonic) else { return }
        let duration = min(8,max(0,(window.captureEndsAt-Date().timeIntervalSince1970*1000)/1000))
        guard duration > 0 else { gate.endCapture(); error = "Capture window expired before camera startup."; return }
        clearMedia(); capturing = true; activeCapture = epoch; captureStart = monotonic; lastFrameAt = -10; status = "Capturing up to 8 seconds in memory"
        if liveMockPreview {
            frames = recentPreviewFrames.filter { captureStart - $0.time <= 3 }.map {
                FramePayload(offsetMs: ($0.time - captureStart) * 1000,jpeg: $0.jpeg)
            }
            frameCount = frames.count
        }
        captureTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration)); guard let self,!Task.isCancelled,self.operation == token else { return }; self.finishCapture(window,token: token)
        }
        Task { [weak self] in guard let self else { return }; do {
            if !self.liveMockPreview {
                try await self.glasses.startCapture(includeGlassesAudio: self.session?.consent.audio == true && self.settings.audio == .glasses)
            }
            try self.checkOperation(token)
            guard self.capturing,self.activeCapture == epoch else { if !self.liveMockPreview { self.glasses.stopCapture() }; return }
            if self.session?.consent.audio == true {
                if self.settings.audio == .phone,self.settings.keywords != .phone,!self.settings.elevenLabsListening { try await self.phone.start(localASR: false); guard self.capturing,self.operation == token else { self.phone.stop(); return } }
                if self.settings.audio == .replay { try self.startReplayAudio(token: token) }
            }
        } catch { guard self.operation == token else { return }; self.error = error.localizedDescription; self.stop() } }
    }
    private func receiveFrame(_ image: UIImage) {
        let now = monotonic
        if liveMockPreview { preview = image }
        let captureFrame = capturing && activeCapture.map { gate.accepts($0,now: now) } == true &&
            frames.count < 6 && now - captureStart - lastFrameAt >= 0.85
        let bufferFrame = armed && liveMockPreview && settings.consent.cloud &&
            (recentPreviewFrames.last.map { now - $0.time >= 0.85 } ?? true)
        guard captureFrame || bufferFrame else { return }
        let offset = now-captureStart
        let size = image.size, scale = min(1,640/max(size.width,size.height)), target = CGSize(width: size.width*scale,height: size.height*scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let reduced = UIGraphicsImageRenderer(size: target,format: format).image { _ in image.draw(in: CGRect(origin: .zero,size: target)) }
        var jpeg: Data?
        for quality: CGFloat in [0.65,0.45,0.25] { if let data = reduced.jpegData(compressionQuality: quality),data.count <= 131072 { jpeg = data; break } }
        guard let jpeg else { return }
        if bufferFrame {
            recentPreviewFrames.append((now,jpeg))
            if recentPreviewFrames.count > 3 { recentPreviewFrames.removeFirst() }
        }
        guard captureFrame else { return }
        frames.append(FramePayload(offsetMs: min(8000,offset*1000),jpeg: jpeg)); frameCount = frames.count; lastFrameAt = offset; preview = reduced
        #if DEBUG
        debugLastCaptureFrames = frames.count
        if debugStopAfterFirstFrame { debugStopAfterFirstFrame = false; stop() }
        #endif
    }
    private func receivePCM(_ samples: [Int16],source: AudioMode,arrivedAt:Double) {
        guard armed else { return }
        if voice.suppressInput {
            speechPCM.removeAll(keepingCapacity: true); speechHasSound = false
            return
        }
        if source == .phone, settings.elevenLabsListening { monitorSpeech(samples) }
        if loudness.consume(samples,time: monotonic) { status = capturing ? "Loud audio during capture · evidence only" : "Loud audio detected locally · no capture triggered" }
        guard arrivedAt >= captureStart,capturing,session?.consent.audio == true,settings.audio == source,let epoch = activeCapture,gate.accepts(epoch,now: monotonic) else { return }
        pcm.append(contentsOf: samples.prefix(max(0,128000-pcm.count))); audioSeconds = Double(pcm.count)/16000
    }
    private func monitorSpeech(_ samples: [Int16]) {
        guard let api, let session, !samples.isEmpty else { return }
        speechHasSound = speechHasSound || samples.contains { abs(Int($0)) >= 450 }
        speechPCM.append(contentsOf: samples)
        guard speechPCM.count >= 64_000 else { return }
        let clip = Array(speechPCM.prefix(64_000))
        speechPCM.removeFirst(56_000)
        let hasSound = speechHasSound
        speechHasSound = false
        guard hasSound, speechTask == nil else { return }
        struct Transcript: Decodable { let text: String }
        let token = operation
        speechTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.operation == token { self.speechTask = nil } }
            do {
                let body = AudioPayload(wav: PCM16WAV.encode(clip),source: "phone")
                let result: Transcript = try await api.post("v1/sessions/\(session.id)/speech",body: body)
                try self.checkOperation(token)
                self.cloudSpeechStatus = result.text.isEmpty ? "No speech in last clip" : "Speech recognized"
                self.receiveTranscript(result.text,final: true,confidence: -1)
            } catch {
                guard self.operation == token else { return }
                self.cloudSpeechStatus = error.localizedDescription
            }
        }
    }
    private func receiveTranscript(_ text: String,final: Bool,confidence: Float) {
        guard armed,!voice.suppressInput else { return }
        guard let intent = KeywordDetector.intent(text,isFinal: final,confidence: confidence,isPlayingVoice: voice.suppressInput) else { return }
        switch intent {
        case .cancel: cancelIncident()
        case .sos: sendTrigger(.keyword_sos)
        case .distress:
            guard lastDistressAt.map({ monotonic - $0 >= 30 }) ?? true else { return }
            lastDistressAt = monotonic
            sendTrigger(.keyword_distress)
        case .threat:
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
        if !liveMockPreview { glasses.stopCapture() }
        replayAudioTask?.cancel(); if settings.keywords != .phone && !settings.elevenLabsListening { phone.stop() }
        capturing = false; gate.endCapture(); activeCapture = nil
        guard let session,let api else { clearMedia(); return }
        let audio = pcm.count >= 1600 ? AudioPayload(wav: PCM16WAV.encode(pcm),source: settings.audio.rawValue) : nil
        let payload = ObservationPayload(windowId: window.id,frames: frames,audio: audio,transcript: nil,source: session.source)
        let hasEvidence = !frames.isEmpty || audio != nil
        clearMedia(); guard hasEvidence else { error = "No usable frames or bounded microphone audio arrived in the capture window."; return }
        processing = true; status = "Transcribing audio and asking Nemotron to assess actual evidence"
        uploadTask = Task { [weak self] in guard let self else { return }; do {
            let result: ObservationResult = try await api.post("v1/sessions/\(session.id)/observations",body: payload); try self.checkOperation(token)
            self.processing = false; self.lastEvidence = "\(result.framesAnalyzed) frames analyzed · \(String(format: "%.1f",result.audioDurationMs/1000)) seconds of audio · transcription: \(result.audioTranscriptionSource ?? "none")"; self.detection = result.detection; self.incident = result.incident ?? self.incident; self.shareLocationIfConsented(); self.status = "\(result.detection.source): \(result.detection.label.replacingOccurrences(of: "_",with: " ")) · \(result.detection.confidence) confidence"; await self.handleVoice()
        } catch { guard self.operation == token else { return }; self.processing = false; self.error = error.localizedDescription } }
    }
    private func clearMedia() { frames.removeAll(keepingCapacity: false); pcm.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }; pcm.removeAll(keepingCapacity: false); if !liveMockPreview { preview = nil }; frameCount = 0; audioSeconds = 0 }
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
        guard isForeground,!capturing,!processing,let incident,incident.voiceConsent,let api else { return }
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
