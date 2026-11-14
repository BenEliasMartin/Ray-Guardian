import Combine
import Foundation
import UIKit
import AVFoundation
import MWDATCore
import MWDATCamera
import MWDATDisplay
import MWDATInputs
import MWDATMotion
import MWDATSpeech
import GuardianCore
#if DEBUG
import MWDATMockDevice
#endif

@MainActor final class GlassesAdapter: ObservableObject {
    /// Several frames per second let keyframe selection skip blurred frames around a fall.
    static let captureFrameRate: UInt = 7
    @Published var status = "Disconnected"
    @Published var motionStatus = "Off"
    @Published var speechStatus = "Off"
    @Published var cameraStatus = "Off"
    @Published private(set) var displayStatus = "Off"
    var configurationError: String?
    private func requireConfiguration() throws { if let configurationError { throw DeviceError.message(configurationError) } }
    var onFrame: ((UIImage) -> Void)?
    var onPCM: (([Int16],Double) -> Void)?
    var onTranscript: ((String, Bool, Float) -> Void)?
    var onMotion: ((MotionPoint) -> Void)?
    var onUnavailable: ((String) -> Void)?
    var onDisplayCancel: ((String) -> Void)?
    private var session: DeviceSession?, camera: Camera?, motion: Motion?, speech: Speech?
    private var imageDecoder: StreamImageDecoder?
    private var stoppingCamera: Camera?
    private let standbyTokens = ListenerTokenBag(), cameraTokens = ListenerTokenBag()
    private var motionSamplesReceived = 0
    private var motionTask: Task<Void,Never>?
    private var display: Display?
    private var displayTask: Task<Void,Never>?
    private var inputTask: Task<Void,Never>?
    private var displayedIncident: String?
    private var displayedDeadline: Date?
    private var generation = UUID()
    private var cameraGeneration = UUID()
    private var speechFailure: String?
    private var speechSuppressed = false
    private var speechResumeTask: Task<Void,Never>?
    private var selector: AutoDeviceSelector?
    #if DEBUG
    private var mock: (any MockGlasses)?
    private var mockVideo: URL?
    private var mockFeedConfigured = false
    #endif

    func register() async throws { try requireConfiguration(); try await Wearables.shared.startRegistration() }
    func requestPermissions() async throws {
        try requireConfiguration()
        guard try await Wearables.shared.requestPermission(.camera) == .granted else { throw DeviceError.message("Glasses camera permission denied.") }
        guard try await Wearables.shared.requestPermission(.microphone) == .granted else { throw DeviceError.message("Glasses microphone permission denied.") }
    }
    func prepareMock(video: URL?, motionCSV: URL? = nil) async throws {
        try requireConfiguration()
        stop()
        #if DEBUG
        if let mock { await MockDeviceKit.shared.unpairDevice(mock); self.mock = nil }
        if video == nil {
            guard AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil else {
                throw DeviceError.message("Run the live mock camera on an iPhone, or choose a replay for the Xcode Simulator.")
            }
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                throw DeviceError.message("Allow Ray Guardian to use the iPhone camera in Settings.")
            }
        }
        try Task.checkCancellation()
        MockDeviceKit.shared.enable()
        MockDeviceKit.shared.permissions.set(.camera, .granted)
        MockDeviceKit.shared.permissions.set(.microphone, .granted)
        let glasses = try MockDeviceKit.shared.pairGlasses(model: .rayBanMeta)
        // Configure the camera feed only when an accepted event starts capture.
        // Pairing/arming must not start the phone's mock camera source.
        mockVideo = video; mockFeedConfigured = false
        glasses.services.speech.setTranscriptionSource(.injected)
        if let motionCSV { glasses.services.motion.setMotionFeed(fileURL: motionCSV) }
        glasses.powerOn(); glasses.unfold(); glasses.don(); mock = glasses
        status = video == nil ? "Mock glasses paired · live iPhone camera" : "Mock glasses paired · video replay"
        #else
        throw DeviceError.message("MockDeviceKit is available in the Debug build.")
        #endif
    }
    func useReal() async {
        guard configurationError == nil else { return }
        stop()
        #if DEBUG
        if let mock { await MockDeviceKit.shared.unpairDevice(mock); self.mock = nil }
        await MockDeviceKit.shared.disable()
        #endif
    }
    func startStandby(useSpeech: Bool, requireSpeech: Bool = false) async throws {
        try requireConfiguration()
        stop(); let token = generation
        let selector = AutoDeviceSelector(wearables: Wearables.shared); self.selector = selector
        let deadline = ProcessInfo.processInfo.systemUptime+15
        while selector.activeDevice == nil {
            try Task.checkCancellation()
            guard token == generation, ProcessInfo.processInfo.systemUptime < deadline else { throw DeviceError.message("No eligible glasses. Check pairing, power, hinges and wear state.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard token == generation else { throw CancellationError() }
        let deviceSession = try Wearables.shared.createSession(deviceSelector: selector); session = deviceSession
        deviceSession.errorPublisher.listen { [weak self] error in Task { @MainActor in guard self?.generation == token else { return }; self?.onUnavailable?(error.localizedDescription) } }.store(in: standbyTokens)
        deviceSession.statePublisher.listen { [weak self] state in Task { @MainActor in
            guard let self, self.generation == token else { return }; self.status = "Glasses session: \(state.description)"
            if state == .paused || state == .stopped { self.onUnavailable?("Glasses session \(state.description)") }
        } }.store(in: standbyTokens)
        try deviceSession.start()
        while deviceSession.state != .started {
            try Task.checkCancellation()
            guard token == generation, ProcessInfo.processInfo.systemUptime < deadline else { stop(); throw DeviceError.message("Glasses session did not start.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        displayStatus = deviceSession.device?.supportsDisplay() == true ? "Off" : "No screen · audio check-ins"
        if let device = deviceSession.device {
            device.addDeviceStateListener { [weak self] state in Task { @MainActor in
                guard let self, self.generation == token else { return }
                if state.donState == .doffed || state.hingeState == .closed || state.linkState == .disconnected || [ThermalLevel.severe,.critical,.emergency,.shutdown].contains(state.thermalLevel) || (state.batteryLevel.map { $0 <= 5 } ?? false) { self.onUnavailable?("Glasses unavailable, removed, low battery or too warm.") }
            } }.store(in: standbyTokens)
        }
        do {
            if let attached = try deviceSession.addMotion(configuration: MotionConfiguration(samplingRate: .hz30)) {
                motion = attached
                attached.errorPublisher.listen { [weak self] error in Task { @MainActor in guard self?.generation == token else { return }; self?.motionStatus = error.localizedDescription } }.store(in: standbyTokens)
                attached.statePublisher.listen { [weak self] state in Task { @MainActor in guard self?.generation == token else { return }; self?.motionStatus = String(describing: state) } }.store(in: standbyTokens)
                motionTask = Task { [weak self] in
                    for await sample in attached.samples {
                        guard !Task.isCancelled, let self, self.generation == token else { break }
                        self.motionSamplesReceived += 1
                        if self.motionSamplesReceived == 1 || self.motionSamplesReceived % 30 == 0 { self.motionStatus = "Receiving \(String(describing:sample.source)) samples (\(self.motionSamplesReceived))" }
                        if sample.source == .glasses, let a = sample.accelerometer {
                            let r = sample.gyroscope
                            self.onMotion?(MotionPoint(time: Double(sample.timestampNs)/1e9, x: Double(a.x), y: Double(a.y), z: Double(a.z),
                                                       rotationX: r.map { Double($0.x) }, rotationY: r.map { Double($0.y) }, rotationZ: r.map { Double($0.z) }))
                        }
                    }
                }
                attached.start()
            } else { motionStatus = "Motion unavailable on this device" }
        } catch { motionStatus = "Motion unavailable: \(error.localizedDescription)" }
        if useSpeech {
            do {
                guard try await Wearables.shared.checkPermissionStatus(.microphone) == .granted else { throw DeviceError.message("Glasses microphone permission required.") }
                if let attached = try deviceSession.addSpeech() {
                    speech = attached
                    speechFailure = nil; speechSuppressed = false
                    attached.transcriptionPublisher.listen { [weak self] result in Task { @MainActor in guard self?.generation == token else { return }; self?.onTranscript?(result.text,result.isFinal,result.confidence) } }.store(in: standbyTokens)
                    attached.statePublisher.listen { [weak self] state in Task { @MainActor in guard self?.generation == token else { return }; self?.speechStatus = String(describing: state) } }.store(in: standbyTokens)
                    attached.errorPublisher.listen { [weak self] error in Task { @MainActor in
                        guard let self,self.generation == token else { return }
                        self.speechFailure = error.localizedDescription; self.speechStatus = error.localizedDescription
                        if requireSpeech,!self.speechSuppressed { self.onUnavailable?("Selected glasses speech failed: \(error.localizedDescription)") }
                    } }.store(in: standbyTokens)
                    attached.start()
                    if requireSpeech {
                        let speechDeadline = ProcessInfo.processInfo.systemUptime+5
                        while attached.state != .started {
                            try Task.checkCancellation()
                            guard generation == token,session === deviceSession else { throw CancellationError() }
                            guard speechFailure == nil,ProcessInfo.processInfo.systemUptime < speechDeadline else {
                                throw DeviceError.message(speechFailure ?? "Glasses speech did not start.")
                            }
                            try await Task.sleep(for:.milliseconds(100))
                        }
                    }
                } else { throw DeviceError.message("Speech unavailable on these glasses or this Meta developer configuration.") }
            } catch {
                speechStatus = "Speech unavailable: \(error.localizedDescription)"
                if requireSpeech { throw DeviceError.message("\(speechStatus) Enable Meta Speech capability and microphone permission, or explicitly choose Phone local speech in Setup.") }
            }
        }
    }
    func startCapture(includeGlassesAudio: Bool) async throws {
        try requireConfiguration()
        stopCapture(); let token = cameraGeneration
        try await waitForCameraStopped()
        guard let session, session.state == .started else { throw DeviceError.message("No started glasses session.") }
        guard try await Wearables.shared.checkPermissionStatus(.camera) == .granted else { throw DeviceError.message("Glasses camera permission required.") }
        if includeGlassesAudio, try await Wearables.shared.checkPermissionStatus(.microphone) != .granted { throw DeviceError.message("Glasses microphone permission required.") }
        guard token == cameraGeneration, self.session === session, session.state == .started, !Task.isCancelled else { throw CancellationError() }
        #if DEBUG
        if let mock,!mockFeedConfigured {
            if let mockVideo { mock.services.camera.setCameraFeed(fileURL:mockVideo) }
            else { mock.services.camera.setCameraFeed(cameraFacing:.back) }
            mockFeedConfigured = true
        }
        #endif
        let config = StreamConfiguration(videoCodec: .hvc1, audioCodec: includeGlassesAudio ? .pcm(sampleRate: .rate16000, numberOfChannels: 1) : nil, resolution: .low, frameRate: 7)
        guard let attached = try session.addCamera(config: config) else { throw DeviceError.message("Camera unavailable.") }
        camera = attached
        let decoder = StreamImageDecoder(); imageDecoder = decoder
        attached.stream.videoFramePublisher.listen { [weak self] frame in
            guard let image = decoder.decode(frame.sampleBuffer) else { return }
            Task { @MainActor in guard let self, self.cameraGeneration == token else { return }; self.onFrame?(image) }
        }.store(in: cameraTokens)
        attached.stream.audioFramePublisher.listen { [weak self] frame in
            let arrivedAt = ProcessInfo.processInfo.systemUptime
            let pcm = PCMConverter.samples(frame.pcmBuffer)
            Task { @MainActor in guard self?.cameraGeneration == token else { return }; self?.onPCM?(pcm,arrivedAt) }
        }.store(in: cameraTokens)
        attached.stream.errorPublisher.listen { [weak self] error in Task { @MainActor in guard self?.cameraGeneration == token else { return }; self?.onUnavailable?("Camera: \(error.localizedDescription)") } }.store(in: cameraTokens)
        attached.stream.statePublisher.listen { [weak self] state in Task { @MainActor in guard self?.cameraGeneration == token else { return }; self?.cameraStatus = String(describing: state) } }.store(in: cameraTokens)
        attached.stream.start(); cameraStatus = "Starting bounded stream"
    }
    func stopCapture() {
        cameraGeneration = UUID(); cameraTokens.clear()
        if let camera { stoppingCamera = camera; camera.stop() }
        camera = nil; imageDecoder?.close(); imageDecoder = nil; cameraStatus = "Off"
    }
    func waitForCameraStopped() async throws {
        guard let camera = stoppingCamera else { return }
        let deadline = ProcessInfo.processInfo.systemUptime+2
        while camera.state != .stopped {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw DeviceError.message("Glasses camera did not stop; spoken output is not confirmed.") }
            try await Task.sleep(for:.milliseconds(50))
        }
        if stoppingCamera === camera { stoppingCamera = nil }
    }
    func showCheckIn(id: String, startedAt: Date, deadline: Date) {
        guard displayedIncident != id || displayedDeadline != deadline, let session, session.state == .started,
              session.device?.supportsDisplay() == true else { return }
        displayedIncident = id
        displayedDeadline = deadline
        displayTask?.cancel()
        inputTask?.cancel()
        inputTask = nil
        try? session.removeInputs()
        displayTask = Task { [weak self] in
            guard let self else { return }
            do {
                let display = try self.display ?? session.addDisplay()
                self.display = display
                if display.state == .stopped { display.start() }
                while display.state != .started && Date() < deadline {
                    try await Task.sleep(for: .milliseconds(100))
                }
                try Task.checkCancellation()
                guard Date() < deadline, self.displayedIncident == id, self.displayedDeadline == deadline, self.session === session else { return }
                // The native button works even if optional band input is unavailable.
                if let inputs = try? session.addInputs(configuration: InputsConfiguration(sources: [.neuralBand], consumeBack: false)) {
                    self.inputTask = Task { [weak self] in
                        for await event in inputs.events {
                            guard !Task.isCancelled, let self, self.displayedIncident == id, self.displayedDeadline == deadline, Date() < deadline else { break }
                            if case .select(source: .neuralBand, timestampMs: _) = event {
                                self.onDisplayCancel?(id)
                            }
                        }
                    }
                }
                let countdown = QuietHalo.Countdown(startedAt:startedAt.timeIntervalSince1970*1000,deadline:deadline.timeIntervalSince1970*1000)
                // DAT supplies layout primitives. Keep its native cancel action and
                // render only the small halo icon; send at most one update per second.
                while Date() < deadline {
                    try Task.checkCancellation()
                    guard self.displayedIncident == id, self.displayedDeadline == deadline, self.session === session else { return }
                    let reading = countdown?.reading(at:Date().timeIntervalSince1970*1000)
                    if reading?.seconds == 0 { break }
                    let content = FlexBox(direction:.column,alignment:.end,crossAlignment:.end) {
                        FlexBox(direction:.row,spacing:10,crossAlignment:.center) {
                            MWDATDisplay.Image(image:QuietHaloDisplayImage.ring(reading),sizePreset:.icon)
                            FlexBox(direction:.column,spacing:2) {
                                MWDATDisplay.Text("Are you okay?",style:.body)
                                MWDATDisplay.Text(reading.map { "\($0.seconds)s · Demo check-in" } ?? "Demo check-in",style:.meta,color:.secondary)
                            }
                            MWDATDisplay.Button(label:"I’m okay",style:.outline,onClick:{ [weak self] in
                                Task { @MainActor in
                                    guard let self,self.displayedIncident == id,self.displayedDeadline == deadline,Date() < deadline else { return }
                                    self.onDisplayCancel?(id)
                                }
                            }).actionRole(.primary)
                        }.padding(10).background(.card)
                    }.padding(16)
                    try await display.send(content)
                    guard !Task.isCancelled,self.displayedIncident == id,self.displayedDeadline == deadline,self.session === session else { return }
                    self.displayStatus = "Quiet halo check-in on glasses"
                    try await Task.sleep(for:.seconds(min(1,max(0,deadline.timeIntervalSinceNow))))
                }
                // A local clock reaching zero is not proof that an alert was sent.
                guard self.displayedIncident == id,self.displayedDeadline == deadline else { return }
                self.inputTask?.cancel()
                self.inputTask = nil
                try? session.removeInputs()
                try await display.clearDisplay()
                self.displayStatus = "Check-in expired · awaiting server status"
            } catch {
                guard !Task.isCancelled, self.displayedIncident == id, self.displayedDeadline == deadline else { return }
                self.displayStatus = "Glasses check-in or gesture unavailable: \(error.localizedDescription)"
            }
        }
    }

    func clearCheckIn() {
        guard displayedIncident != nil else { return }
        displayedIncident = nil
        displayedDeadline = nil
        displayTask?.cancel()
        inputTask?.cancel()
        inputTask = nil
        if let session { try? session.removeInputs() }
        displayTask = Task { [display] in
            guard !Task.isCancelled, let display, display.state == .started else { return }
            try? await display.clearDisplay()
        }
        displayStatus = "Off"
    }

    func stop() {
        generation = UUID()
        clearCheckIn()
        displayTask?.cancel()
        displayTask = nil
        display?.stop()
        display = nil
        stopCapture()
        standbyTokens.clear()
        motionTask?.cancel()
        motionTask = nil
        speechResumeTask?.cancel()
        speechResumeTask = nil
        speech?.stop()
        motion?.stop()
        session?.stop()
        speech = nil
        motion = nil
        session = nil
        selector = nil
        motionStatus = "Off"
        speechStatus = "Off"
        status = "Stopped"
    }
    func setVoiceSuppressed(_ value: Bool) {
        guard speechSuppressed != value else { return }
        speechSuppressed = value
        speechResumeTask?.cancel()
        if value { speech?.stop(); return }
        guard let speech,session?.state == .started else { return }
        let token = generation
        speechResumeTask = Task { [weak self] in
            let deadline = ProcessInfo.processInfo.systemUptime+2
            while speech.state == .stopping || speech.state == .starting {
                guard !Task.isCancelled,let self,self.generation == token,!self.speechSuppressed else { return }
                guard ProcessInfo.processInfo.systemUptime < deadline else { self.onUnavailable?("Glasses speech did not resume after the spoken cue."); return }
                try? await Task.sleep(for:.milliseconds(50))
            }
            guard !Task.isCancelled,let self,self.generation == token,!self.speechSuppressed,self.session?.state == .started else { return }
            if speech.state == .stopped { speech.start() }
        }
    }
    func injectSpeech(_ text: String) {
        #if DEBUG
        mock?.services.speech.simulateTranscription(text: text, isFinal: true, confidence: 0.95)
        #endif
    }
    func replayMotion() {
        #if DEBUG
        // Upright, a short free fall, an impact with a fast head rotation, then lying still on the side.
        var samples: [MWDATMockDevice.MotionSample] = []
        func add(_ ms: Int, _ ax: Float, _ az: Float, spin: Float = 0) {
            samples.append(MWDATMockDevice.MotionSample(timestampNs: Int64(ms)*1_000_000, accelerometer: MWDATMockDevice.Vector3(x: ax,y: 0,z: az),
                                                        gyroscope: MWDATMockDevice.Vector3(x: 0,y: spin,z: 0),source: .glasses))
        }
        for ms in stride(from: 0, to: 1_000, by: 33) { add(ms, 0, 9.8) }
        for ms in stride(from: 1_000, to: 1_300, by: 33) { add(ms, 0.6, 1.5, spin: 4) }
        add(1_330, 22, 18, spin: 7); add(1_363, 14, 6, spin: 3)
        for ms in stride(from: 1_396, to: 6_000, by: 33) { add(ms, 9.8, 0.2) }
        let token = generation
        Task { [weak self] in
            guard let self, let motion = self.motion, let mock = self.mock else { return }
            motion.stop()
            let deadline = ProcessInfo.processInfo.systemUptime+2
            while motion.state != .stopped && ProcessInfo.processInfo.systemUptime < deadline {
                try? await Task.sleep(for:.milliseconds(20))
                guard self.generation == token else { return }
            }
            guard self.generation == token,motion.state == .stopped else { self.motionStatus = "Mock motion restart timed out"; return }
            self.motionSamplesReceived = 0
            mock.services.motion.setMotionFeed(samples)
            motion.start()
        }
        #endif
    }
    func mockFault(_ fault: String) {
        #if DEBUG
        switch fault { case "disconnect": mock?.powerOff(); case "doff": mock?.doff(); case "thermal": mock?.setThermalLevel(.severe); case "permission": MockDeviceKit.shared.permissions.set(.camera,.denied); default: break }
        #endif
    }
}
enum DeviceError: LocalizedError { case message(String); var errorDescription: String? { if case let .message(text) = self { return text }; return nil } }
