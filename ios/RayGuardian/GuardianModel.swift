import Foundation
import UIKit
import Combine
import AVFoundation
import ImageIO
import GuardianCore

@MainActor final class GuardianModel: ObservableObject {
    #if DEBUG
    @Published private(set) var debugLastCaptureFrames = 0
    var debugStopAfterFirstFrame = false
    #endif
    let settings = Settings(), glasses = GlassesAdapter(), phone = PhoneAudio(), voice = VoicePlayer(), replays = ReplayLibrary()
    private let phoneCamera = PhoneCamera()
    let heartRate = HeartRateMonitor(), locator = IncidentLocation(), phoneMotion = PhoneMotion()
    private var phoneFall = FallCandidateDetector(), phoneMotionActive = false
    private var heartRateDetector = SustainedHeartRate(), located = Set<String>()
    @Published private(set) var session: GuardianSession?
    @Published private(set) var incident: Incident? {
        didSet { updateAlertPresentation(previous: oldValue) }
    }
    @Published private(set) var detection: Detection?
    @Published private(set) var health: Health?
    @Published private(set) var armed = false
    @Published private(set) var developerOptionsEnabled = UserDefaults.standard.bool(forKey: "guardian.developerOptions")
    @Published private(set) var demoDispatch: DemoDispatch? {
        didSet {
            if oldValue?.incidentID != demoDispatch?.incidentID || oldValue?.service != demoDispatch?.service {
                updateIncidentAnimation()
            }
            if let demoDispatch { glasses.showDemoDispatch(demoDispatch, animation: incidentAnimation) }
        }
    }
    private var audibleAlertID: String? { demoDispatch?.incidentID }
    private var incidentCoordinates: (id: String, coordinates: IncidentCoordinates)?
    private var locatingIncidentID: String?
    @Published private(set) var incidentAnimation: IncidentAnimation.Presentation?
    @Published private(set) var capturing = false
    @Published private(set) var processing = false
    @Published private(set) var status = "Ready to configure"
    @Published private(set) var frameCount = 0
    @Published private(set) var audioSeconds = 0.0
    @Published private(set) var preview: UIImage?
    @Published private(set) var liveMockPreview = false
    @Published private(set) var starting = false
    @Published var selectedResponder: DemoDispatch.Service = .police
    @Published private(set) var manualEmergencyPending = false
    private var manualResponder: (incidentID: String, service: DemoDispatch.Service)?
    @Published private(set) var glassesRecordingStarting = false
    @Published private(set) var glassesRecordingActive = false
    @Published private(set) var glassesRecordingSaving = false
    @Published private(set) var glassesRecordingURL: URL?
    private static let glassesRecordingLimit = 45
    private var glassesRecordingFrames: [IncidentFrame] = []
    private var glassesRecordingAudio: IncidentClipAudio?
    private var glassesRecordingCues: [(time: Double, speech: String?)] = []
    private var glassesRecordingTimer: Task<Void, Never>?
    private var cameraOpenedForRecording = false
    @Published private(set) var lastEvidence = ""
    @Published var error: String?
    @Published private(set) var history: [Incident] = []
    private let incidentEvidence = IncidentEvidence()
    private var evidenceWrites: [String: Task<Void, Never>] = [:]
    private var savedEvidenceIDs = Set<String>()
    @Published private(set) var historyError = false
    private var api: GuardianAPI?, gate = PrivacyGate(), operation = UUID(), fall = FallCandidateDetector(), loudness = LoudnessDetector()
    private var captureTask: Task<Void,Never>?, replayAudioTask: Task<Void,Never>?, heartbeatTask: Task<Void,Never>?, uploadTask: Task<Void,Never>?
    private var candidates: [IncidentFrame] = [], pcm: [Int16] = [], captureStart = 0.0, captureDeadline = 0.0, lastFrameAt = -10.0, activeCapture: UUID?
    private var localEvidenceIncident: Incident?
    private var clipAudio: IncidentClipAudio?
    /// The camera stays on while armed for preview, pre-trigger frames, or hand gestures.
    @Published private(set) var continuousCamera = false
    var handGesturesActive: Bool {
        guard settings.input != .phone, settings.handGestures, settings.consent.capture else { return false }
        #if DEBUG
        if settings.input == .mock && settings.mockUsesReplay { return false }
        #endif
        return true
    }
    private var handHold = HandGestureHold(), handSampleAt = -10.0, handSampleInFlight = false
    @Published private(set) var practiceGesture: HandGesture?
    @Published private(set) var practiceError: String?
    @Published private(set) var gestureFeedback: GestureFeedback = .waiting
    enum GestureFeedback: Equatable { case waiting, noHand, handVisible, holding, recognized, unavailable }
    private var practiceGeneration = UUID()
    private var practiceTask: Task<Void, Never>?
    private var handIncidentID: String?, gestureTriggerPending = false
    private var openIncidentID: String? { incident.flatMap { $0.terminal ? nil : $0.id } }
    private var earlyCameraRequests = 0, earlyCameraTask: Task<Void,Error>?
    private var motionRecorder = MotionRecorder(), lastFallPattern: FallPattern?
    private var disarmTask: Task<Void,Never>?
    private var alertDeadlineTask: Task<Void, Never>?
    private var demoCallTask: Task<Void, Never>?
    private var lastThreatAt: Double?
    private var lastDistressAt: Double?
    /// In-memory only: at most the last three seconds, uploaded only inside an accepted capture window.
    private var recentPreviewFrames: [IncidentFrame] = []
    private var phoneSpeechActive = false
    private var spoken = Set<String>(), relays = Set<AnyCancellable>(), isForeground = true
    init() {
        heartRate.onMeasurement = { [weak self] bpm in guard let self,self.armed,self.settings.heartRateEnabled else { return }; if self.heartRateDetector.consume(bpm:bpm,threshold:self.settings.heartRateThreshold,time:self.monotonic) { self.sendTrigger(.heart_rate) } }
        voice.$playing.sink { [weak self] playing in
            guard let self else { return }
            self.phone.setSuppressed(playing); self.glasses.setVoiceSuppressed(playing)
        }.store(in:&relays)
        glasses.onFrame = { [weak self] in self?.receiveFrame($0) }
        phoneCamera.onFrame = { [weak self] in self?.receiveFrame($0) }
        glasses.onPCM = { [weak self] in self?.receivePCM($0,source: .glasses,arrivedAt:$1) }
        phone.onPCM = { [weak self] in self?.receivePCM($0,source: .phone,arrivedAt:$1) }
        phone.onFailure = { [weak self] message in
            guard let self else { return }
            self.error = message
            if self.settings.input == .phone {
                self.phone.stop()
                self.phoneSpeechActive = false
            } else {
                self.stop()
            }
        }
        glasses.onTranscript = { [weak self] in self?.receiveTranscript($0,final: $1,confidence: $2) }
        phone.onTranscript = { [weak self] text, final, confidence in
            self?.receivePhoneTranscript(text, final: final, confidence: confidence)
        }
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
        phoneMotion.onFailure = { [weak self] message in
            guard let self else { return }
            self.phoneMotionActive = false
            self.error = message
            if self.settings.input != .phone { self.stop() }
        }
        glasses.onUnavailable = { [weak self] message in
            guard let self, self.settings.input != .phone else { return }
            if self.practiceGesture != nil, !self.armed {
                self.setGesturePractice(nil)
                self.practiceError = message
            } else if self.starting || self.armed || self.capturing {
                self.stop()
                self.status = message
                self.error = message
            }
        }
        glasses.onDisplayCancel = { [weak self] id in
            guard let self, self.armed, self.isForeground, self.incident?.id == id, self.incident?.terminal == false else { return }
            self.cancelIncident()
        }
        settings.objectWillChange.sink { [weak self] _ in guard let self else { return }; if self.armed || self.starting { self.stop() } }.store(in: &relays)
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification).sink { [weak self] note in
            guard let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  type == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor in
                guard let self, self.armed else { return }
                if self.settings.input == .phone {
                    self.phone.stop()
                    self.phoneSpeechActive = false
                    self.error = "The iPhone microphone was interrupted. Rearm to resume listening."
                } else {
                    self.stop()
                    self.error = "Audio interrupted; session stopped."
                }
            }
        }.store(in: &relays)
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification).sink { [weak self] note in
            guard let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt, reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            Task { @MainActor in
                guard let self, self.armed, self.settings.input != .phone else { return }
                self.stop()
                self.error = "Audio device disconnected; session stopped."
            }
        }.store(in: &relays)
    }
    #if DEBUG
    func statusForUITesting() { status = "UI TEST FIXTURE · live providers disabled" }
    #endif
    func makeAPI() throws -> GuardianAPI { try GuardianAPI(url: settings.apiURL,token: settings.clientToken) }
    func checkBackend() async { do { try settings.save(); let client = try makeAPI(); health = try await client.get("health"); status = health?.ready == true ? "Backend and provider keys configured" : "Backend connected; provider keys still need configuration" } catch { self.error = error.localizedDescription } }
    func checkGlassesConnection() async {
        guard !armed, !starting else { return }
        error = nil
        #if DEBUG
        if settings.input == .mock { settings.input = .real }
        #endif
        await glasses.checkConnection()
    }

    func setDeveloperOptions(_ enabled: Bool) {
        guard enabled != developerOptionsEnabled else { return }
        developerOptionsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "guardian.developerOptions")
        guard !enabled else { return }
        if glassesRecordingStarting || settings.input == .mock {
            if starting || armed { stop() }
            if settings.input == .mock { settings.input = .real }
        }
        setGesturePractice(nil)
        finishGlassesRecording()
    }

    func startGlassesRecording() async {
        guard developerOptionsEnabled, !starting, !glassesRecordingStarting,
              !glassesRecordingActive, !glassesRecordingSaving else { return }
        guard settings.input == .real, settings.consent.capture else {
            error = "Select real glasses and enable camera capture in Settings."
            return
        }
        glassesRecordingStarting = true
        defer { glassesRecordingStarting = false }
        error = nil
        let needsDedicatedCamera = !continuousCamera && !settings.preTriggerFrames && !handGesturesActive
        if !armed { await arm() }
        guard developerOptionsEnabled, armed, isForeground else { return }
        let token = operation
        do {
            if capturing && !continuousCamera {
                self.error = "Wait for the current incident capture to finish, then record."
                return
            }
            if !continuousCamera {
                try await glasses.startCapture(includeGlassesAudio: true, verifyFirstFrame: true, allowVideoWithoutAudio: true)
                try checkOperation(token)
                cameraOpenedForRecording = true
                continuousCamera = true
            } else if needsDedicatedCamera {
                cameraOpenedForRecording = true
            }
            glassesRecordingFrames.removeAll()
            glassesRecordingCues.removeAll()
            glassesRecordingAudio = IncidentClipAudio(start: monotonic, duration: Self.glassesRecordingLimit)
            glassesRecordingActive = true
            glassesRecordingTimer = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(Self.glassesRecordingLimit)) } catch { return }
                self?.finishGlassesRecording()
            }
        } catch {
            guard operation == token else { return }
            glasses.stopCapture()
            self.error = "Couldn’t start the glasses recording: \(error.localizedDescription)"
        }
    }

    func finishGlassesRecording() {
        guard glassesRecordingActive else { return }
        glassesRecordingActive = false
        glassesRecordingTimer?.cancel()
        glassesRecordingTimer = nil
        if cameraOpenedForRecording {
            cameraOpenedForRecording = false
            continuousCamera = false
            if !capturing { glasses.stopCapture() }
        }
        let frames = glassesRecordingFrames
        let capturedAudio = glassesRecordingAudio
        let cues = glassesRecordingCues
        glassesRecordingFrames.removeAll()
        glassesRecordingAudio = nil
        glassesRecordingCues.removeAll()
        glassesRecordingSaving = true
        Task {
            defer { glassesRecordingSaving = false }
            do {
                guard frames.count >= 3 else {
                    throw DeviceError.message("Keep the glasses on and record for at least a second.")
                }
                var audio = capturedAudio
                for cue in cues where cue.time < (frames.last?.time ?? 0) {
                    let samples: [Int16]
                    if let speech = cue.speech {
                        samples = await voice.renderSpeech(speech)
                    } else {
                        samples = VoicePlayer.alertToneSamples()
                    }
                    var track = IncidentClipAudio(start: cue.time, duration: Self.glassesRecordingLimit)
                    track.append(samples, endingAt: cue.time + Double(samples.count) / Double(IncidentClipAudio.sampleRate))
                    audio?.mix(track)
                }
                let url = try await incidentEvidence.exportGlassesVideo(frames, audio: audio)
                if let old = glassesRecordingURL { try? FileManager.default.removeItem(at: old.deletingLastPathComponent()) }
                glassesRecordingURL = url
            } catch {
                self.error = "Couldn’t save the glasses recording: \(error.localizedDescription)"
            }
        }
    }

    func requestPhoneCameraPermission() async {
        if !(await phoneCamera.requestPermission()) {
            error = "Allow camera access for Ray Guardian in iPhone Settings."
        }
    }

    func arm() async {
        guard !armed, !starting else { return }
        setGesturePractice(nil)
        guard settings.input == .phone || (!glasses.checkingConnection && !glasses.requestingPermission) else {
            error = "Wait for the glasses check to finish, then arm again."
            return
        }
        error = nil
        let token = UUID(); operation = token; starting = true; status = "Preparing local triggers"
        defer { if operation == token { starting = false } }
        do {
            guard !settings.consent.audio || settings.consent.cloud else { throw DeviceError.message("Audio sharing also requires cloud sharing consent.") }
            guard settings.input != .real || settings.audio != .replay else { throw DeviceError.message("Choose a real microphone source for real-glasses mode.") }
            await disarmTask?.value; try checkOperation(token)
            try settings.save(); let client = try makeAPI(); api?.invalidate(); api = client
            if settings.input != .phone {
                if settings.input == .mock {
                    #if DEBUG
                    let clip = settings.mockUsesReplay ? replays.selected : nil
                    let video = replays.url(clip?.video)
                    if settings.mockUsesReplay, video == nil { throw DeviceError.message("Choose an available replay in Mock glasses, or switch to the live iPhone camera.") }
                    try await glasses.prepareMock(video: video,motionCSV: replays.url(clip?.motion))
                    #endif
                } else { await glasses.useReal() }
                try checkOperation(token)
                try await glasses.startStandby(useSpeech: settings.keywords == .glasses || settings.input == .mock, requireSpeech: settings.input == .real && settings.keywords == .glasses); try checkOperation(token)
                #if DEBUG
                if settings.input == .mock, !settings.mockUsesReplay, settings.consent.capture {
                    try await glasses.startCapture(includeGlassesAudio: glassesCaptureAudio)
                    try checkOperation(token)
                    liveMockPreview = true; continuousCamera = true
                }
                #endif
                if !continuousCamera, settings.consent.capture,
                   settings.preTriggerFrames || handGesturesActive || glassesRecordingStarting {
                    try await glasses.startCapture(includeGlassesAudio: glassesCaptureAudio || glassesRecordingStarting,
                                                   verifyFirstFrame: settings.input == .real,
                                                   allowVideoWithoutAudio: glassesRecordingStarting)
                    try checkOperation(token)
                    continuousCamera = true
                }
            }
            if speechMode == .phone {
                do {
                    try await phone.start(localASR: true, listenForCancel: true)
                    try checkOperation(token)
                    phoneSpeechActive = true
                } catch {
                    try checkOperation(token)
                    guard settings.input == .phone else { throw error }
                    phone.stop()
                    self.error = "Speech monitoring is unavailable. You can still trigger a check-in from this iPhone."
                }
            } else if settings.input == .phone, settings.consent.capture,
                      settings.recordClipAudio || settings.consent.audio {
                do {
                    try await phone.requestPermissions(localSpeech: false)
                } catch {
                    self.error = "Microphone access is off. Incident clips can still include video."
                }
                try checkOperation(token)
            }
            let phoneMotionTesting = settings.input == .mock && settings.phoneMotionTesting
            var localAlertConsent = settings.consent
            if settings.input == .phone, localAlertConsent.capture {
                localAlertConsent.capture = await phoneCamera.requestPermission()
                try checkOperation(token)
                if !localAlertConsent.capture {
                    error = "Camera access is off. Guardian can still check in using the iPhone."
                }
            }
            localAlertConsent.demoCalls = false
            localAlertConsent.backgroundEscalation = false
            let created: GuardianSession = try await client.post("v1/sessions",body: CreateSession(consent: localAlertConsent,source: settings.input.captureSource,phoneMotionTesting: phoneMotionTesting,handGestures: handGesturesActive)); try checkOperation(token)
            let active: GuardianSession = try await client.post("v1/sessions/\(created.id)/arm"); try checkOperation(token)
            let remaining = ((active.armedUntil ?? 0) / 1000) - Date().timeIntervalSince1970
            session = active
            guard active.armed, remaining > 0 else { throw DeviceError.message("The backend arming window expired.") }
            incident = nil; detection = nil; lastEvidence = ""; spoken.removeAll(); fall = FallCandidateDetector(); motionRecorder.reset(); lastFallPattern = nil; lastThreatAt = nil; lastDistressAt = nil
            gate.arm(consent: localAlertConsent,now: monotonic,duration: remaining)
            armed = true
            status = "Armed · camera off until triggered"
            if continuousCamera { status = "Armed · live camera" }
            demoDispatch = nil
            if settings.input != .phone { glasses.showMonitoring() }
            phoneFall = FallCandidateDetector()
            if settings.input == .phone || phoneMotionTesting {
                do {
                    try phoneMotion.start()
                    phoneMotionActive = true
                } catch {
                    if phoneMotionTesting { throw error }
                    self.error = "iPhone motion is unavailable. You can still trigger a check-in manually."
                }
            }
            heartbeatTask?.cancel(); heartbeatTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5)); guard let self,!Task.isCancelled,self.operation == token,self.armed else { return }
                    do {
                        let refreshed: GuardianSession = try await client.post("v1/sessions/\(active.id)/heartbeat"); guard self.operation == token else { return }
                        self.session = refreshed
                        if !refreshed.armed || (refreshed.armedUntil ?? 0) <= Date().timeIntervalSince1970*1000 { self.stop(); return }
                        await self.refreshIncident()
                    } catch { guard self.operation == token else { return }; self.error = "Backend heartbeat lost: \(error.localizedDescription)"; self.stop(); return }
                }
            }
        } catch { guard operation == token else { return }; stop(); self.status = error.localizedDescription; self.error = status }
    }
    private var monotonic: Double { ProcessInfo.processInfo.systemUptime }
    private func checkOperation(_ token: UUID) throws { guard token == operation,isForeground,!Task.isCancelled else { throw CancellationError() } }
    func stop(cancelPending: Bool = true) {
        finishGlassesRecording()
        if capturing, let capturedIncident = localEvidenceIncident ?? incident,
           capturedIncident.sessionId == session?.id {
            saveEvidence(candidates, audio: clipAudio, for: capturedIncident)
        }
        let oldSession = session, client = api
        operation = UUID(); gate.invalidate(); armed = false; starting = false; liveMockPreview = false; continuousCamera = false; capturing = false; processing = false; activeCapture = nil
        earlyCameraRequests = 0; earlyCameraTask?.cancel(); earlyCameraTask = nil; motionRecorder.reset(); lastFallPattern = nil
        alertDeadlineTask?.cancel(); alertDeadlineTask = nil
        demoCallTask?.cancel(); demoCallTask = nil
        demoDispatch = nil
        manualEmergencyPending = false
        manualResponder = nil
        incidentCoordinates = nil; locatingIncidentID = nil
        incidentAnimation = nil
        captureTask?.cancel(); replayAudioTask?.cancel(); uploadTask?.cancel(); heartbeatTask?.cancel()
        recentPreviewFrames.removeAll()
        handHold = HandGestureHold(); handSampleAt = -10; handIncidentID = nil; gestureTriggerPending = false
        setGesturePractice(nil)
        setGestureFeedback(.waiting)
        phoneSpeechActive = false
        phoneCamera.stop(); glasses.stop(); phone.stop(); phoneMotion.stop(); phoneMotionActive = false; voice.stop(); locator.cancel(); clearMedia(); status = "Disarmed · camera and local triggers off"
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
    func triggerEmergency() async {
        guard developerOptionsEnabled || (settings.input == .phone && armed),
              !starting, !glassesRecordingStarting, !manualEmergencyPending, isForeground, demoDispatch == nil else { return }
        let responder = selectedResponder
        if !armed { await arm() }
        guard developerOptionsEnabled || settings.input == .phone,
              armed, !manualEmergencyPending, isForeground, demoDispatch == nil else { return }
        sendTrigger(.manual_sos, responder: responder)
    }

    func sendTrigger(_ signal: TriggerSignal, responder: DemoDispatch.Service? = nil) {
        guard armed, let session, let api else { return }
        let token = operation, triggeredAt = monotonic
        if signal == .manual_sos {
            guard !manualEmergencyPending else { return }
            manualEmergencyPending = true
            error = nil
        }
        if signal == .gesture_distress {
            guard handGesturesActive, practiceGesture == nil, !gestureTriggerPending, openIncidentID == nil else { return }
            gestureTriggerPending = true
        }
        // Start the camera now, in parallel with the server round trip, so the moments right after a fall are
        // not lost. Frames stay in memory and are discarded unless the server opens a capture window.
        let early = startEarlyCamera()
        Task { [weak self] in
            guard let self else { return }
            defer {
                if self.operation == token {
                    if signal == .manual_sos, self.manualEmergencyPending {
                        self.manualEmergencyPending = false
                        self.updateAlertPresentation(previous: nil)
                    }
                    if signal == .gesture_distress { self.gestureTriggerPending = false }
                }
            }
            do {
                let path = "v1/sessions/\(session.id)/triggers"
                var reply: TriggerReply = try await api.post(path, body: TriggerBody(signal))
                try self.checkOperation(token)
                if signal == .motion_phone, session.source == .phone, reply.reason == "source_disabled" {
                    reply = try await api.post(path, body: TriggerBody(.motion))
                    try self.checkOperation(token)
                }
                if signal == .manual_sos, reply.incident == nil {
                    self.error = "The emergency could not be started. Try again."
                }
                if signal == .gesture_distress, reply.incident == nil, self.openIncidentID == nil {
                    self.setGestureFeedback(.waiting)
                    self.error = reply.accepted
                        ? "Guardian saw the fist, but the service didn’t open a check-in."
                        : "Guardian saw the fist, but this session didn’t accept a check-in. Disarm and arm again."
                }
                if signal == .manual_sos, let incident = reply.incident, !incident.terminal {
                    if let responder { self.manualResponder = (incident.id, responder) }
                    self.manualEmergencyPending = false
                }
                self.session = reply.session
                self.incident = reply.incident ?? self.incident
                self.shareLocationIfConsented()
                self.status = reply.reason.replacingOccurrences(of: "_",with: " ")
                if let window = reply.window,!self.capturing,!self.processing { self.beginCapture(window,token: token,triggeredAt: triggeredAt,early: early) }
                else {
                    if let incident = reply.incident { self.recordLocalEvidence(for: incident, token: token, early: early) }
                    else { self.endEarlyCamera(early) }
                }
                await self.handleVoice()
            } catch { guard self.operation == token else { return }; self.endEarlyCamera(early); self.error = error.localizedDescription }
        }
    }
    private var captureAudioMode: AudioMode { settings.input == .phone ? .phone : settings.audio }
    private var speechMode: KeywordMode {
        settings.input == .phone && settings.keywords == .glasses ? .phone : settings.keywords
    }

    private func startIncidentCamera(includeGlassesAudio: Bool) async throws {
        if settings.input == .phone { try await phoneCamera.start() }
        else { try await glasses.startCapture(includeGlassesAudio: includeGlassesAudio) }
    }

    private func stopIncidentCamera() {
        if settings.input == .phone { phoneCamera.stop() }
        else { glasses.stopCapture() }
    }

    private var glassesCaptureAudio: Bool {
        settings.audio == .glasses && (settings.consent.audio || settings.recordClipAudio)
    }
    private func startEarlyCamera() -> Bool {
        guard !continuousCamera,!capturing,!processing,session?.consent.capture == true,session?.consent.cloud == true else { return false }
        earlyCameraRequests += 1
        if earlyCameraRequests == 1 {
            recentPreviewFrames.removeAll()
            let audio = glassesCaptureAudio
            earlyCameraTask = Task { [weak self] in guard let self else { return }; try await self.startIncidentCamera(includeGlassesAudio: audio) }
        }
        return true
    }
    private func endEarlyCamera(_ early: Bool) {
        guard early,earlyCameraRequests > 0 else { return }
        earlyCameraRequests -= 1
        guard earlyCameraRequests == 0,!capturing,!continuousCamera else { return }
        earlyCameraTask?.cancel(); earlyCameraTask = nil; stopIncidentCamera(); recentPreviewFrames.removeAll()
    }
    private func beginCapture(_ window: CaptureWindow,token: UUID,triggeredAt: Double,early: Bool) {
        guard let epoch = gate.beginCapture(now: monotonic) else { endEarlyCamera(early); return }
        let now = monotonic, start = max(triggeredAt,now-3)
        // Offsets are measured from the trigger itself; the capture never runs past eight seconds after it.
        let duration = min(8-(now-start),max(0,(window.captureEndsAt-Date().timeIntervalSince1970*1000)/1000))
        guard duration > 0 else { gate.endCapture(); endEarlyCamera(early); error = "Capture window expired before camera startup."; return }
        clearMedia(); capturing = true; activeCapture = epoch; captureStart = start; captureDeadline = now + duration; lastFrameAt = -10; status = "Capturing up to 8 seconds in memory"
        if settings.recordClipAudio { clipAudio = IncidentClipAudio(start: start) }
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
                try self.checkOperation(token)
                guard self.activeCapture == epoch else { return }
                if !running { try await self.startIncidentCamera(includeGlassesAudio: self.glassesCaptureAudio) }
            }
            try self.checkOperation(token)
            guard self.activeCapture == epoch else { return }
            await self.startCaptureAudio(token: token, epoch: epoch, allowCloud: self.session?.consent.audio == true)
        } catch {
            guard self.operation == token, self.activeCapture == epoch else { return }
            self.error = error.localizedDescription
            if self.settings.input != .phone { self.stop() }
        } }
    }
    private func receiveFrame(_ image: UIImage) {
        let now = monotonic
        if glassesRecordingActive, glassesRecordingFrames.count < Self.glassesRecordingLimit * Int(GlassesAdapter.captureFrameRate),
           glassesRecordingFrames.last.map({ now - $0.time >= 1.0 / 8 }) ?? true,
           let frame = GlassesRecordingOverlay.frame(image, dispatch: demoDispatch, animation: incidentAnimation,
                                                    checkingIn: incident?.state == "check_in", time: now) {
            glassesRecordingFrames.append(frame)
        }
        if continuousCamera || practiceGesture != nil { preview = image }
        recognizeHandGesture(in: image, at: now)
        let captureFrame = capturing && now <= captureDeadline && activeCapture.map { gate.accepts($0,now: now) } == true &&
            candidates.count < 80 && now - captureStart - lastFrameAt >= 0.125
        let preTriggerBuffer = continuousCamera && settings.input != .phone && (settings.preTriggerFrames || liveMockPreview)
        let bufferFrame = armed && (preTriggerBuffer || earlyCameraRequests > 0) && settings.consent.capture &&
            (recentPreviewFrames.last.map { now - $0.time >= 0.125 } ?? true)
        guard captureFrame || bufferFrame else { return }
        let offset = now-captureStart
        let size = image.size, scale = min(1,640/max(size.width,size.height)), target = CGSize(width: size.width*scale,height: size.height*scale)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let reduced = UIGraphicsImageRenderer(size: target,format: format).image { _ in image.draw(in: CGRect(origin: .zero,size: target)) }
        var jpeg: Data?
        for quality: CGFloat in [0.65,0.45,0.25] { if let data = reduced.jpegData(compressionQuality: quality),data.count <= 131072 { jpeg = data; break } }
        guard let jpeg else { return }
        let frame = IncidentFrame(time: now, jpeg: jpeg, sharpness: Self.sharpness(reduced))
        if bufferFrame {
            recentPreviewFrames.append(frame)
            recentPreviewFrames.removeAll { now - $0.time > 3 }
        }
        guard captureFrame else { return }
        if candidates.last.map({ $0.time < now }) ?? true { candidates.append(frame) }
        if let localEvidenceIncident, lastFrameAt == -10 {
            // Give the clip five seconds of video, within the existing eight-second capture limit.
            captureDeadline = min(captureDeadline, now + 5)
            if let epoch = activeCapture { scheduleLocalEvidenceFinish(for: localEvidenceIncident, token: operation, epoch: epoch) }
        }
        frameCount = min(KeyframeSelector.maximumFrames,candidates.count); lastFrameAt = offset
        if !continuousCamera { preview = reduced }
        #if DEBUG
        debugLastCaptureFrames = candidates.count
        if debugStopAfterFirstFrame { debugStopAfterFirstFrame = false; stop() }
        #endif
    }
    func setGesturePractice(_ gesture: HandGesture?) {
        let canPractice = developerOptionsEnabled && handGesturesActive && isForeground && !starting && openIncidentID == nil &&
            (armed ? continuousCamera : settings.input == .real)
        let next = canPractice ? gesture : nil
        guard practiceGesture != next else { return }
        let wasPracticing = practiceGesture != nil
        practiceGesture = next
        practiceGeneration = UUID()
        practiceError = nil
        setGestureFeedback(.waiting)
        handHold = HandGestureHold()
        guard !armed else { return }
        if next == nil {
            practiceTask?.cancel()
            practiceTask = nil
            glasses.stop()
            preview = nil
        } else if !wasPracticing {
            practiceTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.glasses.startPracticeCamera()
                } catch {
                    guard !Task.isCancelled, self.practiceGesture != nil else { return }
                    self.setGesturePractice(nil)
                    self.practiceError = error.localizedDescription
                }
            }
        }
    }

    private func setGestureFeedback(_ feedback: GestureFeedback) {
        if gestureFeedback != feedback { gestureFeedback = feedback }
    }

    private func recognizeHandGesture(in image: UIImage, at time: Double) {
        guard (armed && continuousCamera || practiceGesture != nil), isForeground, handGesturesActive, !handSampleInFlight,
              time - handSampleAt >= 0.19, let frame = image.cgImage else { return }
        let incidentID = openIncidentID
        if handIncidentID != incidentID {
            handHold = HandGestureHold()
            handIncidentID = incidentID
            setGestureFeedback(.waiting)
        }
        if incidentID != nil { setGesturePractice(nil) }
        let practice = practiceGesture
        let practiceToken = practiceGeneration
        let gesture: HandGesture = practice ?? (incidentID == nil ? .fist : .shaka)
        let orientation: CGImagePropertyOrientation
        switch image.imageOrientation {
        case .up: orientation = .up
        case .down: orientation = .down
        case .left: orientation = .left
        case .right: orientation = .right
        case .upMirrored: orientation = .upMirrored
        case .downMirrored: orientation = .downMirrored
        case .leftMirrored: orientation = .leftMirrored
        case .rightMirrored: orientation = .rightMirrored
        @unknown default: return
        }
        handSampleAt = time; handSampleInFlight = true
        let token = operation
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                CameraHandPose.recognize(gesture, in: frame, orientation: orientation)
            }.value
            guard let self else { return }
            self.handSampleInFlight = false
            guard self.operation == token, self.armed || self.practiceGesture != nil,
                  self.isForeground, self.openIncidentID == incidentID,
                  self.practiceGeneration == practiceToken else { return }
            if self.monotonic - time > 0.8 {
                self.handHold = HandGestureHold()
                self.setGestureFeedback(.waiting)
                return
            }
            let held = self.handHold.consume(matches: result == .matches, at: time, allowingOneMiss: true)
            if held || (practice != nil && self.gestureFeedback == .recognized && result == .matches) {
                self.setGestureFeedback(.recognized)
            } else if self.handHold.isHolding {
                self.setGestureFeedback(.holding)
            } else {
                switch result {
                case .noHand: self.setGestureFeedback(.noHand)
                case .unavailable: self.setGestureFeedback(.unavailable)
                case .handVisible, .matches: self.setGestureFeedback(.handVisible)
                }
            }
            guard held, practice == nil else { return }
            switch gesture {
            case .fist: self.sendTrigger(.gesture_distress)
            case .shaka: self.cancelIncident()
            }
        }
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
        if glassesRecordingActive, source == .glasses, !voice.playing {
            glassesRecordingAudio?.append(samples, endingAt: arrivedAt)
        }
        if voice.suppressInput { return }
        if loudness.consume(samples,time: monotonic) { status = capturing ? "Loud audio during capture · evidence only" : "Loud audio detected locally · no capture triggered" }
        guard arrivedAt >= captureStart, arrivedAt <= captureDeadline, capturing, captureAudioMode == source,
              let epoch = activeCapture, gate.accepts(epoch, now: monotonic) else { return }
        clipAudio?.append(samples, endingAt: arrivedAt)
        guard localEvidenceIncident == nil, session?.consent.audio == true else { return }
        pcm.append(contentsOf: samples.prefix(max(0,128000-pcm.count))); audioSeconds = Double(pcm.count)/16000
    }
    private func receivePhoneTranscript(_ text: String, final: Bool, confidence: Float) {
        guard armed else { return }
        if (!voice.suppressInput || incident?.terminal == false),
           KeywordDetector.isCancelCommand(text, isFinal: final, confidence: confidence) {
            cancelIncident()
            return
        }
        if speechMode == .phone { receiveTranscript(text, final: final, confidence: confidence) }
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
    private var phoneListensWhileArmed: Bool { phoneSpeechActive }

    private func startCaptureAudio(token: UUID, epoch: UUID, allowCloud: Bool) async {
        guard allowCloud || clipAudio != nil else { return }
        if captureAudioMode == .phone { phone.captureEnabled = true }
        do {
            if captureAudioMode == .phone, !phoneListensWhileArmed {
                try await phone.start(localASR: false)
                if operation == token, (!capturing || activeCapture != epoch) { phone.stop() }
            }
            if captureAudioMode == .replay, operation == token, capturing, activeCapture == epoch {
                try startReplayAudio(token: token)
            }
        } catch {
            guard operation == token, capturing, activeCapture == epoch else { return }
            if captureAudioMode == .phone, !phoneListensWhileArmed { phone.stop() }
            status = "Capture audio unavailable: \(error.localizedDescription)"
        }
    }

    private func startReplayAudio(token: UUID) throws {
        guard let url = replays.url(replays.selected?.audio) else { throw DeviceError.message("No replay WAV selected. Prepare media or choose another audio input.") }
        let samples = try PCM16WAV.decode(Data(contentsOf: url))
        replayAudioTask = Task { [weak self] in
            for start in stride(from: 0,to: samples.count,by: 320) {
                guard !Task.isCancelled,let self,self.operation == token,self.capturing else { return }
                let chunk = Array(samples[start..<min(start+320,samples.count)])
                self.receivePCM(chunk, source: .replay, arrivedAt: self.monotonic + Double(chunk.count) / 16_000)
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
    }
    private func finishCapture(_ window: CaptureWindow,token: UUID) {
        if !continuousCamera,earlyCameraRequests == 0 { stopIncidentCamera(); recentPreviewFrames.removeAll() }
        replayAudioTask?.cancel(); if !phoneListensWhileArmed { phone.stop() }
        capturing = false; gate.endCapture(); activeCapture = nil
        guard let session,let api else { clearMedia(); return }
        let audio = pcm.count >= 1600 ? AudioPayload(wav: PCM16WAV.encode(pcm),source: captureAudioMode.rawValue) : nil
        let picked = KeyframeSelector.select(offsets: candidates.map { $0.time-captureStart },sharpness: candidates.map { $0.sharpness })
        let frames = picked.map { FramePayload(offsetMs: min(8000,max(-3000,((candidates[$0].time-captureStart)*1000).rounded())),jpeg: candidates[$0].jpeg) }
        let recordedFrames = candidates
        let recordedAudio = clipAudio
        let knownIncident = incident.flatMap { $0.sessionId == session.id && !$0.terminal ? $0 : nil }
        if let knownIncident { saveEvidence(recordedFrames, audio: recordedAudio, for: knownIncident) }
        let motion = motionRecorder.summary(triggerAt: captureStart,endAt: min(monotonic,captureDeadline),fallPattern: [TriggerSignal.motion.rawValue,TriggerSignal.motion_phone.rawValue].contains(window.signal) ? lastFallPattern : nil)
        let payload = ObservationPayload(windowId: window.id,frames: frames,audio: audio,transcript: nil,source: session.source,motion: motion)
        let hasEvidence = !frames.isEmpty || audio != nil
        clearMedia(); guard hasEvidence else {
            error = "The camera and microphone didn’t provide a usable recording."
            Task { await handleVoice() }
            return
        }
        processing = true; status = "Transcribing audio and asking Nemotron to assess actual evidence"
        Task { await handleVoice() }
        uploadTask = Task { [weak self] in guard let self else { return }; do {
            let result: ObservationResult = try await api.post("v1/sessions/\(session.id)/observations",body: payload); try self.checkOperation(token)
            if let confirmed = result.incident, confirmed.id != knownIncident?.id {
                self.saveEvidence(recordedFrames, audio: recordedAudio, for: confirmed)
            }
            self.processing = false; self.lastEvidence = "\(result.framesAnalyzed) frames analyzed · \(String(format: "%.1f",result.audioDurationMs/1000)) seconds of audio · transcription: \(result.audioTranscriptionSource ?? "none")"; self.detection = result.detection; self.incident = result.incident ?? self.incident; self.shareLocationIfConsented(); self.status = "\(result.detection.source): \(result.detection.label.replacingOccurrences(of: "_",with: " ")) · \(result.detection.confidence) confidence"; await self.handleVoice()
        } catch {
            guard self.operation == token else { return }
            self.processing = false
            self.status = error.localizedDescription
            self.error = "Cloud analysis couldn’t finish. Guardian is still armed."
            await self.handleVoice()
        } }
    }
    private func clearMedia() { phone.captureEnabled = false; clipAudio = nil; localEvidenceIncident = nil; candidates.removeAll(keepingCapacity: false); pcm.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) }; pcm.removeAll(keepingCapacity: false); if !armed && !continuousCamera { preview = nil }; frameCount = 0; audioSeconds = 0 }
    func refreshIncident() async {
        guard let id = session?.incidentId ?? incident?.id,let api else { return }; let epoch = operation
        do {
            let value: Incident = try await api.get("v1/incidents/\(id)")
            guard operation == epoch,(session?.incidentId ?? incident?.id) == id else { return }
            incident = value; detection = value.detection ?? detection
            await handleVoice()
        } catch { if operation == epoch { self.error = error.localizedDescription } }
    }
    private func updateIncidentAnimation() {
        let dispatch = demoDispatch.flatMap { $0.incidentID == incident?.id ? $0 : nil }
        incidentAnimation = IncidentAnimation.update(
            previous: incidentAnimation, incident: armed ? incident : nil,
            now: Date().timeIntervalSince1970, fallback: dispatch?.service.animation,
            preferred: manualResponder.flatMap { $0.incidentID == incident?.id ? $0.service.animation : nil }
        )
    }

    private func updateAlertPresentation(previous: Incident?) {
        updateIncidentAnimation()
        guard armed, let incident, !incident.terminal else {
            alertDeadlineTask?.cancel()
            alertDeadlineTask = nil
            if audibleAlertID != nil {
                demoCallTask?.cancel()
                demoCallTask = nil
                voice.stop()
            }
            demoDispatch = nil
            if armed { glasses.showMonitoring() }
            return
        }
        if incident.state == "check_in", audibleAlertID != incident.id, let deadline = incident.checkInDeadline {
            glasses.showCheckIn(id: incident.id, deadline: Date(timeIntervalSince1970: deadline / 1000), animation: incidentAnimation)
            guard previous?.id != incident.id || previous?.checkInDeadline != deadline else { return }
            alertDeadlineTask?.cancel()
            let id = incident.id
            let remaining = max(0, deadline / 1000 - Date().timeIntervalSince1970)
            alertDeadlineTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
                guard let self, self.armed, self.isForeground, self.incident?.id == id,
                      self.incident?.terminal == false else { return }
                self.beginDemoDispatch(id: id)
            }
        } else {
            alertDeadlineTask?.cancel()
            alertDeadlineTask = nil
            beginDemoDispatch(id: incident.id)
        }
    }

    private func beginDemoDispatch(id: String) {
        guard armed, isForeground, !manualEmergencyPending, audibleAlertID != id,
              let incident, incident.id == id else { return }
        let responder = manualResponder.flatMap { $0.incidentID == id ? $0.service : nil }
        var dispatch = DemoDispatch(incident: incident, requestedService: responder)
        if let local = incidentCoordinates, local.id == id { dispatch.coordinates = local.coordinates }
        demoDispatch = dispatch
        demoCallTask?.cancel()
        demoCallTask = Task { [weak self] in
            guard let self, self.demoDispatch?.incidentID == id else { return }
            self.playAlertTone()
            do {
                try await Task.sleep(for: .seconds(2))
                guard self.demoDispatch?.incidentID == id else { return }
                let latest = self.incident.flatMap { $0.id == id ? DemoDispatch(incident: $0, requestedService: responder) : nil }
                if var connected = latest, let current = self.demoDispatch {
                    connected.coordinates = current.coordinates ?? connected.coordinates
                    connected.phase = .connected
                    self.demoDispatch = connected
                }
                // Give a pending GPS fix and capture a few seconds to finish before speaking.
                let deadline = ContinuousClock.now + .seconds(9)
                while (self.locatingIncidentID == id || self.capturing), ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(200))
                }
                if self.settings.input == .real, !self.continuousCamera {
                    try? await self.glasses.waitForCameraStopped()
                    try Task.checkCancellation()
                }
                guard let current = self.demoDispatch, current.incidentID == id,
                      let incident = self.incident, incident.id == id else { return }
                var briefing = DemoDispatch(incident: incident, requestedService: responder)
                briefing.coordinates = current.coordinates ?? briefing.coordinates
                briefing.phase = .briefing
                self.demoDispatch = briefing
                self.voice.usesPhoneMicrophone = self.phoneListensWhileArmed
                try self.voice.speak(briefing.spokenBriefing)
                if self.glassesRecordingActive {
                    self.glassesRecordingCues.append((self.monotonic, briefing.spokenBriefing))
                }
                let audioDeadline = ContinuousClock.now + .seconds(30)
                while self.voice.playing, ContinuousClock.now < audioDeadline {
                    try await Task.sleep(for: .milliseconds(150))
                }
                guard var current = self.demoDispatch, current.incidentID == id else { return }
                current.phase = .complete
                self.demoDispatch = current
            } catch is CancellationError {
                return
            } catch {
                guard self.demoDispatch?.incidentID == id else { return }
                self.error = "The call briefing couldn’t play: \(error.localizedDescription)"
            }
        }
    }

    private func handleVoice() async {
        guard isForeground, armed, let incident, incident.state == "check_in", audibleAlertID != incident.id,
              let deadline = incident.checkInDeadline, Date().timeIntervalSince1970 * 1000 < deadline else { return }
        let screenless = !glasses.hasDisplay && settings.speakWithoutDisplay
        if screenless, settings.input == .real, !continuousCamera {
            guard !capturing else { return }
            try? await glasses.waitForCameraStopped()
            guard isForeground, armed, self.incident?.id == incident.id, self.incident?.state == "check_in",
                  audibleAlertID != incident.id, Date().timeIntervalSince1970 * 1000 < deadline else { return }
        }
        let key = incident.id + ":check_in"
        guard spoken.insert(key).inserted else { return }
        if settings.input == .phone || screenless { playSpokenCheckIn() }
        else { playAlertTone() }
    }

    func playAlertTone() {
        voice.usesPhoneMicrophone = armed && (phoneListensWhileArmed || (settings.input == .phone && phone.captureEnabled))
        do {
            try voice.playAlertTone()
            if glassesRecordingActive { glassesRecordingCues.append((monotonic, nil)) }
        }
        catch { self.error = "Couldn’t play the alert tone." }
    }

    func playSpokenCheckIn() {
        voice.usesPhoneMicrophone = armed && (phoneListensWhileArmed || (settings.input == .phone && phone.captureEnabled))
        do { try voice.speakCheckIn() }
        catch { self.error = "Spoken check-in unavailable: \(error.localizedDescription)" }
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
    private func shareLocationIfConsented() {
        guard let incident,session?.consent.location == true,!located.contains(incident.id),let api else { return }
        located.insert(incident.id); let token = operation
        locatingIncidentID = incident.id
        Task { [weak self] in
            guard let self else { return }
            defer { if self.operation == token, self.locatingIncidentID == incident.id { self.locatingIncidentID = nil } }
            do {
                let location = try await self.locator.current(); try self.checkOperation(token)
                guard self.incident?.id == incident.id, self.incident?.terminal == false else { return }
                let coordinates = IncidentCoordinates(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                                                      accuracyMeters: location.horizontalAccuracy)
                self.incidentCoordinates = (incident.id, coordinates)
                if var dispatch = self.demoDispatch, dispatch.incidentID == incident.id {
                    dispatch.coordinates = coordinates
                    self.demoDispatch = dispatch
                }
                self.locatingIncidentID = nil
                struct Body: Encodable { let latitude:Double,longitude:Double,accuracyMeters:Double,timestamp:Double }
                let value: Incident = try await api.post("v1/incidents/\(incident.id)/location",body:Body(latitude:location.coordinate.latitude,longitude:location.coordinate.longitude,accuracyMeters:location.horizontalAccuracy,timestamp:location.timestamp.timeIntervalSince1970*1000))
                guard self.incident?.id == incident.id,self.operation == token else { return }; self.incident = value
            } catch { if self.operation == token { self.error = "Location was not shared: \(error.localizedDescription)" } }
        }
    }
    func replayMotion() { fall = FallCandidateDetector(); glasses.replayMotion() }
    private func recordLocalEvidence(for incident: Incident, token: UUID, early: Bool) {
        let now = monotonic
        guard !capturing, !processing, !incident.terminal, incident.sessionId == session?.id,
              evidenceWrites[incident.id] == nil, !savedEvidenceIDs.contains(incident.id),
              let epoch = gate.beginCapture(now: now, localOnly: true) else { endEarlyCamera(early); return }
        clearMedia()
        localEvidenceIncident = incident
        candidates = recentPreviewFrames.filter { now - $0.time <= 3 }
        captureStart = now
        captureDeadline = now + 8
        if settings.recordClipAudio { clipAudio = IncidentClipAudio(start: now) }
        lastFrameAt = -10
        activeCapture = epoch
        capturing = true

        let pendingCamera = early && earlyCameraRequests > 0 ? earlyCameraTask : nil
        if early { earlyCameraRequests = max(0, earlyCameraRequests - 1) }
        if !continuousCamera { recentPreviewFrames.removeAll() }
        scheduleLocalEvidenceFinish(for: incident, token: token, epoch: epoch)
        Task { [weak self] in
            guard let self else { return }
            do {
                if !self.continuousCamera {
                    var running = false
                    if let pendingCamera { running = (try? await pendingCamera.value) != nil }
                    try self.checkOperation(token)
                    guard self.localEvidenceIncident?.id == incident.id else { return }
                    if !running {
                        try await self.startIncidentCamera(includeGlassesAudio: self.settings.recordClipAudio && self.captureAudioMode == .glasses)
                    }
                }
                try self.checkOperation(token)
                guard self.localEvidenceIncident?.id == incident.id else { return }
                await self.startCaptureAudio(token: token, epoch: epoch, allowCloud: false)
            } catch {
                guard self.operation == token, self.localEvidenceIncident?.id == incident.id else { return }
                self.error = error.localizedDescription
            }
        }
    }

    private func scheduleLocalEvidenceFinish(for incident: Incident, token: UUID, epoch: UUID) {
        captureTask?.cancel()
        let remaining = max(0, captureDeadline - monotonic)
        captureTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            guard let self, self.operation == token, self.activeCapture == epoch,
                  self.localEvidenceIncident?.id == incident.id else { return }
            if !self.continuousCamera, self.earlyCameraRequests == 0 { self.stopIncidentCamera() }
            self.replayAudioTask?.cancel()
            if !self.phoneListensWhileArmed { self.phone.stop() }
            self.saveEvidence(self.candidates, audio: self.clipAudio, for: incident)
            self.capturing = false
            self.activeCapture = nil
            self.gate.endCapture()
            self.clearMedia()
            await self.handleVoice()
        }
    }

    private func saveEvidence(_ frames: [IncidentFrame], audio: IncidentClipAudio?, for incident: Incident) {
        guard !frames.isEmpty, let id = UUID(uuidString: incident.id),
              evidenceWrites[incident.id] == nil, !savedEvidenceIDs.contains(incident.id) else { return }
        let createdAt = Date(timeIntervalSince1970: incident.createdAt / 1000)
        evidenceWrites[incident.id] = Task { [weak self, incidentEvidence] in
            defer { self?.evidenceWrites[incident.id] = nil }
            do {
                try await incidentEvidence.save(frames, audio: audio, id: id, createdAt: createdAt)
                self?.savedEvidenceIDs.insert(incident.id)
            } catch {
                if !Task.isCancelled { self?.error = "Couldn’t save the incident recording on this iPhone." }
            }
        }
    }

    func reviewEvidence(for incident: Incident) async -> ReviewedEvidence {
        guard let id = UUID(uuidString: incident.id) else { return .unavailable }
        await evidenceWrites[incident.id]?.value
        return await incidentEvidence.review(id: id, createdAt: Date(timeIntervalSince1970: incident.createdAt / 1000))
    }

    func isRecordingEvidence(for item: Incident) -> Bool {
        capturing && (localEvidenceIncident?.id ?? incident?.id) == item.id
    }

    func loadHistory() async {
        await incidentEvidence.removeExpired()
        do {
            struct List: Decodable { let incidents: [Incident] }
            let client = try makeAPI()
            history = try await client.get("v1/incidents", as: List.self).incidents
            historyError = false
        } catch { historyError = !Task.isCancelled }
    }

    func deleteIncident(_ item: Incident) async {
        do {
            let client = try makeAPI()
            try await client.delete("v1/incidents/\(item.id)")
            if incident?.id == item.id { incident = nil }
            history.removeAll { $0.id == item.id }
            let write = evidenceWrites[item.id]
            write?.cancel()
            await write?.value
            if let id = UUID(uuidString: item.id) { try await incidentEvidence.delete(id: id) }
            savedEvidenceIDs.remove(item.id)
        } catch { self.error = error.localizedDescription }
    }
}
