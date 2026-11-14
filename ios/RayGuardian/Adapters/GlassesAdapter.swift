import Combine
import Foundation
import UIKit
import AVFoundation
import MWDATCore
import MWDATCamera
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
    var configurationError: String?
    private func requireConfiguration() throws { if let configurationError { throw DeviceError.message(configurationError) } }
    var onFrame: ((UIImage) -> Void)?
    var onPCM: (([Int16],Double) -> Void)?
    var onTranscript: ((String, Bool, Float) -> Void)?
    var onMotion: ((MotionPoint) -> Void)?
    var onUnavailable: ((String) -> Void)?
    private var session: DeviceSession?, camera: Camera?, motion: Motion?, speech: Speech?
    private let standbyTokens = ListenerTokenBag(), cameraTokens = ListenerTokenBag()
    private var motionTask: Task<Void,Never>?
    private var generation = UUID()
    private var cameraGeneration = UUID()
    private var selector: AutoDeviceSelector?
    #if DEBUG
    private var mock: (any MockGlasses)?
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
        if let video { glasses.services.camera.setCameraFeed(fileURL: video) }
        else { glasses.services.camera.setCameraFeed(cameraFacing: .back) }
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
    func startStandby(useSpeech: Bool) async throws {
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
            guard try await Wearables.shared.checkPermissionStatus(.microphone) == .granted else { speechStatus = "Glasses microphone permission required"; return }
            do {
                if let attached = try deviceSession.addSpeech() {
                    speech = attached
                    attached.transcriptionPublisher.listen { [weak self] result in Task { @MainActor in guard self?.generation == token else { return }; self?.onTranscript?(result.text,result.isFinal,result.confidence) } }.store(in: standbyTokens)
                    attached.statePublisher.listen { [weak self] state in Task { @MainActor in guard self?.generation == token else { return }; self?.speechStatus = String(describing: state) } }.store(in: standbyTokens)
                    attached.errorPublisher.listen { [weak self] error in Task { @MainActor in guard self?.generation == token else { return }; self?.speechStatus = error.localizedDescription } }.store(in: standbyTokens)
                    attached.start()
                } else { speechStatus = "Speech unavailable; select phone local speech if needed" }
            } catch { speechStatus = "Speech unavailable: \(error.localizedDescription)" }
        }
    }
    func startCapture(includeGlassesAudio: Bool) async throws {
        try requireConfiguration()
        stopCapture(); let token = cameraGeneration
        guard let session, session.state == .started else { throw DeviceError.message("No started glasses session.") }
        guard try await Wearables.shared.checkPermissionStatus(.camera) == .granted else { throw DeviceError.message("Glasses camera permission required.") }
        if includeGlassesAudio, try await Wearables.shared.checkPermissionStatus(.microphone) != .granted { throw DeviceError.message("Glasses microphone permission required.") }
        guard token == cameraGeneration, self.session === session, session.state == .started, !Task.isCancelled else { throw CancellationError() }
        let config = StreamConfiguration(videoCodec: .raw, audioCodec: includeGlassesAudio ? .pcm(sampleRate: .rate16000, numberOfChannels: 1) : nil, resolution: .low, frameRate: Self.captureFrameRate)
        guard let attached = try session.addCamera(config: config) else { throw DeviceError.message("Camera unavailable.") }
        camera = attached
        attached.stream.videoFramePublisher.listen { [weak self] frame in
            Task { @MainActor in guard let self, self.cameraGeneration == token, let image = frame.makeUIImage() else { return }; self.onFrame?(image) }
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
    func stopCapture() { cameraGeneration = UUID(); cameraTokens.clear(); camera?.stop(); camera = nil; cameraStatus = "Off" }
    func stop() { generation = UUID(); stopCapture(); standbyTokens.clear(); motionTask?.cancel(); motionTask = nil; speech?.stop(); motion?.stop(); session?.stop(); speech = nil; motion = nil; session = nil; selector = nil; motionStatus = "Off"; speechStatus = "Off"; status = "Stopped" }
    func setVoiceSuppressed(_ value: Bool) { if value { speech?.stop() } else { speech?.start() } }
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
        mock?.services.motion.setMotionFeed(samples)
        #endif
    }
    func mockFault(_ fault: String) {
        #if DEBUG
        switch fault { case "disconnect": mock?.powerOff(); case "doff": mock?.doff(); case "thermal": mock?.setThermalLevel(.severe); case "permission": MockDeviceKit.shared.permissions.set(.camera,.denied); default: break }
        #endif
    }
}
enum DeviceError: LocalizedError { case message(String); var errorDescription: String? { if case let .message(text) = self { return text }; return nil } }
