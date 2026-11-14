import Combine
import Foundation
import UIKit
import AVFoundation
import CoreBluetooth
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
    @Published private(set) var requestingPermission = false
    @Published private(set) var permissionStatus = ""
    @Published private(set) var glassesAppUpdateRequired = false
    @Published private(set) var checkingConnection = false
    struct GlassesChoice: Identifiable {
        let id: String
        let name: String
        let hasDisplay: Bool
    }
    @Published private(set) var availableGlasses: [GlassesChoice] = []
    @Published private(set) var preferredGlassesID = UserDefaults.standard.string(forKey: "preferredGlassesID")
    var configurationError: String?
    private func requireConfiguration() throws { if let configurationError { throw DeviceError.message(configurationError) } }
    var onFrame: ((UIImage) -> Void)?
    var onPCM: (([Int16],Double) -> Void)?
    var onTranscript: ((String, Bool, Float) -> Void)?
    var onMotion: ((MotionPoint) -> Void)?
    var onUnavailable: ((String) -> Void)?
    var onDisplayCancel: ((String) -> Void)?
    private var session: DeviceSession?, camera: Camera?, motion: Motion?, speech: Speech?
    private var stoppingCamera: Camera?
    private var closingSession: DeviceSession?
    private var pauseTask: Task<Void, Never>?
    private var linkLossTask: Task<Void, Never>?
    private var waitingForCameraFrame = false
    private var receivedCameraFrame = false
    private var cameraStartupFailure: String?
    private var imageDecoder: StreamImageDecoder?
    private let standbyTokens = ListenerTokenBag(), cameraTokens = ListenerTokenBag()
    private let inputTokens = ListenerTokenBag()
    private var motionTask: Task<Void,Never>?
    private var motionSamplesReceived = 0
    private var speechFailure: String?
    private var speechSuppressed = false
    private var speechResumeTask: Task<Void,Never>?
    private var display: Display?
    private var displayTask: Task<Void,Never>?
    private var inputTask: Task<Void,Never>?
    private enum DisplayPage: Equatable {
        case monitoring, controls
        case checkIn(String, Date, IncidentAnimation.Presentation?)
        case alert(DemoDispatch, IncidentAnimation.Presentation?)

        var animation: IncidentAnimation.Presentation? {
            switch self {
            case .checkIn(_, _, let animation), .alert(_, let animation): return animation
            case .monitoring, .controls: return nil
            }
        }
    }
    private var displayPage: DisplayPage?
    private var displayRenderID = UUID()
    private var sentDisplayID: UUID?
    private var lastDisplaySelect = -Double.infinity
    @Published private(set) var bandStatus = "Off"
    private var generation = UUID()
    private var cameraGeneration = UUID()
    private var selector: (any DeviceSelector)?
    private var waitingForSessionStart = false
    private var sessionStartError: DeviceSessionError?
    #if DEBUG
    private var mock: (any MockGlasses)?
    #endif

    func observeGlasses() async {
        guard configurationError == nil else { return }
        let wearables = Wearables.shared
        func refresh() {
            availableGlasses = wearables.devices.compactMap { id in
                guard let device = wearables.deviceForIdentifier(id) else { return nil }
                let hasDisplay = device.supportsDisplay() || device.deviceType() == .metaRayBanDisplay
                return GlassesChoice(id: id, name: device.nameOrId(), hasDisplay: hasDisplay)
            }
        }
        refresh()
        for await _ in wearables.devicesStream() {
            guard !Task.isCancelled else { break }
            refresh()
        }
    }

    func chooseGlasses(_ id: String?) {
        preferredGlassesID = id
        UserDefaults.standard.set(id, forKey: "preferredGlassesID")
        permissionStatus = ""
        glassesAppUpdateRequired = false
    }

    func register() async throws {
        try requireConfiguration()
        await disableMockIfNeeded()
        let wearables = Wearables.shared
        guard wearables.registrationState != .registered else { return }
        try await wearables.startRegistration()
    }

    func grantCameraPermission() async throws {
        try await grantPermission(.camera, name: "Glasses camera")
    }

    func grantMicrophonePermission() async throws {
        try await grantPermission(.microphone, name: "Glasses microphone")
    }

    private func grantPermission(_ permission: Permission, name: String) async throws {
        try requireConfiguration()
        guard !requestingPermission else { return }
        requestingPermission = true
        defer { requestingPermission = false }
        await disableMockIfNeeded()
        let wearables = Wearables.shared
        guard wearables.registrationState == .registered else {
            throw DeviceError.message("Finish registering Ray Guardian in Meta AI before granting glasses permissions.")
        }
        if CBCentralManager.authorization == .denied || CBCentralManager.authorization == .restricted {
            throw DeviceError.message("Ray Guardian cannot use Bluetooth. Check Settings → Privacy & Security → Bluetooth on the iPhone.")
        }
        permissionStatus = "Checking the glasses connection…"
        do {
            let current = try await permissionStatusAfterConnection(permission, wearables: wearables)
            if current != .granted {
                permissionStatus = "Waiting for \(name.lowercased()) approval in Meta AI…"
                guard try await wearables.requestPermission(permission) == .granted else {
                    throw DeviceError.message("\(name) access was denied in Meta AI.")
                }
            }
            permissionStatus = "\(name) access granted"
        } catch PermissionError.requestTimeout {
            permissionStatus = connectionSummary(wearables)
            throw DeviceError.message("\(name) permission timed out in Meta AI. Wear the glasses, confirm they show as connected in Meta AI, then retry this permission from Ray Guardian. Approve it in Meta AI and let it return to Ray Guardian.")
        } catch PermissionError.noDevice, PermissionError.noDeviceWithConnection, PermissionError.connectionError {
            permissionStatus = connectionSummary(wearables)
            throw DeviceError.message("\(name) permission could not reach the glasses through Meta’s developer connection. \(permissionStatus). In Meta AI, check Developer Mode for this pair and install any offered glasses or developer app update, then retry.")
        } catch let error as PermissionError {
            permissionStatus = connectionSummary(wearables)
            throw DeviceError.message("\(name) permission: \(error.localizedDescription)")
        } catch {
            permissionStatus = connectionSummary(wearables)
            throw error
        }
    }

    private func permissionStatusAfterConnection(_ permission: Permission, wearables: any WearablesInterface) async throws -> PermissionStatus {
        // Discovery and the developer link can finish shortly after returning from Meta AI.
        let deadline = ContinuousClock.now + .seconds(10)
        while true {
            do { return try await wearables.checkPermissionStatus(permission) }
            catch {
                switch error {
                case .noDevice, .noDeviceWithConnection, .connectionError:
                    guard ContinuousClock.now < deadline else { throw error }
                    permissionStatus = connectionSummary(wearables)
                    try await Task.sleep(for: .milliseconds(750))
                default: throw error
                }
            }
        }
    }

    private func connectionSummary(_ wearables: any WearablesInterface) -> String {
        let devices = wearables.devices.compactMap { wearables.deviceForIdentifier($0) }
        if devices.isEmpty { return "No glasses visible to Ray Guardian" }
        if devices.contains(where: { $0.linkState == .connected }) { return "Glasses visible and developer link connected" }
        if devices.contains(where: { $0.linkState == .connecting }) { return "Glasses found, developer link connecting" }
        return "Glasses found, developer link disconnected"
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
        await disableMockIfNeeded()
    }

    func checkConnection() async {
        guard !checkingConnection, !requestingPermission else { return }
        checkingConnection = true
        defer { checkingConnection = false }
        do {
            try requireConfiguration()
            await useReal()
            let session = try await connect()
            let name = session.device?.nameOrId() ?? "Glasses"
            let displayHint = hasDisplay ? " On-glasses check-ins are supported." : ""
            status = "Checking the glasses camera…"
            try await startCapture(includeGlassesAudio: false, verifyFirstFrame: true)
            stop()
            permissionStatus = "\(name) connected. Live video received.\(displayHint)"
        } catch {
            stop()
            permissionStatus = error.localizedDescription
        }
    }

    func testDisplay() async {
        guard !checkingConnection, !requestingPermission else { return }
        checkingConnection = true
        defer { stop(); checkingConnection = false }
        do {
            try requireConfiguration()
            await useReal()
            _ = try await connect()
            guard hasDisplay else {
                throw DeviceError.message("The connected pair doesn’t have a display. Choose the Display pair in Settings.")
            }
            let token = generation
            status = "Opening the glasses display…"
            showMonitoring()
            let deadline = ContinuousClock.now + .seconds(8)
            while sentDisplayID == nil, displayPage != nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
                guard generation == token else { throw CancellationError() }
            }
            guard sentDisplayID != nil else {
                throw DeviceError.message("The glasses connected, but the display card didn’t open. \(displayStatus)")
            }
            status = "Pinch on the Neural Band to try the controls."
            permissionStatus = "Display test card sent."
            try await Task.sleep(for: .seconds(15))
            if generation == token, let display { try? await display.clearDisplay() }
        } catch {
            permissionStatus = error is CancellationError ? "Display test stopped." : error.localizedDescription
        }
    }

    func startPracticeCamera() async throws {
        guard !checkingConnection, !requestingPermission else {
            throw DeviceError.message("Wait for the glasses check to finish before practicing.")
        }
        await useReal()
        _ = try await connect()
        try await startCapture(includeGlassesAudio: false, verifyFirstFrame: true)
    }

    private func disableMockIfNeeded() async {
        #if DEBUG
        if let mock { await MockDeviceKit.shared.unpairDevice(mock); self.mock = nil }
        if MockDeviceKit.shared.isEnabled { await MockDeviceKit.shared.disable() }
        #endif
    }
    func startStandby(useSpeech: Bool, requireSpeech: Bool = false) async throws {
        guard !checkingConnection, !requestingPermission else {
            throw DeviceError.message("Wait for the glasses check to finish, then arm again.")
        }
        let deviceSession = try await connect()
        try await startStandbyCapabilities(deviceSession, useSpeech: useSpeech, requireSpeech: requireSpeech)
    }

    private func connect() async throws -> DeviceSession {
        try requireConfiguration()
        glassesAppUpdateRequired = false
        let wearables = Wearables.shared
        #if DEBUG
        if !MockDeviceKit.shared.isEnabled && wearables.registrationState != .registered {
            throw DeviceError.message("Connect Ray Guardian through Meta AI under Settings → Pairing and permissions.")
        }
        #else
        guard wearables.registrationState == .registered else {
            throw DeviceError.message("Connect Ray Guardian through Meta AI under Settings → Pairing and permissions.")
        }
        #endif
        if CBCentralManager.authorization == .denied || CBCentralManager.authorization == .restricted {
            throw DeviceError.message("Allow Ray Guardian to use Bluetooth in iPhone Settings.")
        }
        for attempt in 0..<3 {
            do {
                return try await startSession(wearables)
            } catch let error as DeviceSessionError {
                if error == .datAppOnTheGlassesUpdateRequired { glassesAppUpdateRequired = true }
                guard attempt < 2, shouldRetrySessionStart(error) else {
                    throw DeviceError.message(sessionErrorMessage(error))
                }
                stop()
                let token = generation
                status = "Reconnecting to glasses…"
                try await Task.sleep(for: .seconds(attempt + 2))
                guard token == generation else { throw CancellationError() }
            }
        }
        throw DeviceError.message("Couldn’t connect to the glasses.")
    }

    private func startSession(_ wearables: any WearablesInterface) async throws -> DeviceSession {
        stop(); let token = generation
        if let closingSession {
            let deadline = ContinuousClock.now + .seconds(4)
            while closingSession.state != .stopped, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
                guard token == generation else { throw CancellationError() }
            }
            if closingSession.state == .stopped { self.closingSession = nil }
        }
        #if DEBUG
        let preferred = MockDeviceKit.shared.isEnabled ? nil : preferredGlassesID
        #else
        let preferred = preferredGlassesID
        #endif
        let selector: any DeviceSelector
        if let preferred {
            selector = SpecificDeviceSelector(device: preferred)
        } else {
            selector = AutoDeviceSelector(wearables: wearables)
        }
        self.selector = selector
        status = "Looking for glasses…"
        let discoveryDeadline = ContinuousClock.now + .seconds(15)
        while selector.activeDevice == nil || preferred.map({ !wearables.devices.contains($0) }) == true {
            try Task.checkCancellation()
            guard token == generation else { throw CancellationError() }
            guard ContinuousClock.now < discoveryDeadline else {
                if preferred != nil {
                    throw DeviceError.message("The selected pair is unavailable. Put it on and check its connection in Meta AI, or choose another pair in Ray Guardian Settings.")
                }
                throw DeviceError.message(connectionRecoveryMessage(wearables))
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard token == generation else { throw CancellationError() }
        let deviceSession = try wearables.createSession(deviceSelector: selector); session = deviceSession
        waitingForSessionStart = true
        status = "Starting glasses session…"
        deviceSession.errorPublisher.listen { [weak self] error in Task { @MainActor in
            guard let self, self.generation == token else { return }
            if error == .datAppOnTheGlassesUpdateRequired { self.glassesAppUpdateRequired = true }
            if self.waitingForSessionStart {
                if self.sessionStartError == nil || error == .datAppOnTheGlassesUpdateRequired { self.sessionStartError = error }
            } else {
                self.reportConnectionFailure(self.sessionErrorMessage(error))
            }
        } }.store(in: standbyTokens)
        deviceSession.statePublisher.listen { [weak self, weak deviceSession] state in Task { @MainActor in
            guard let self, let deviceSession, self.generation == token else { return }
            guard state == deviceSession.state else { return }
            self.status = "Glasses session: \(state.description)"
            guard !self.waitingForSessionStart else { return }
            self.pauseTask?.cancel()
            if state == .stopped {
                self.reportConnectionFailure("The glasses ended the connection. Keep them on and retry.")
            } else if state == .paused {
                self.pauseTask = Task { [weak self, weak deviceSession] in
                    do { try await Task.sleep(for: .seconds(4)) } catch { return }
                    guard let self, self.generation == token, deviceSession?.state == .paused else { return }
                    self.reportConnectionFailure("The glasses connection paused. Keep the glasses on and retry.")
                }
            }
        } }.store(in: standbyTokens)
        do { try deviceSession.start() }
        catch {
            if error == .datAppOnTheGlassesUpdateRequired { glassesAppUpdateRequired = true }
            throw error
        }
        let startupDeadline = ContinuousClock.now + .seconds(25)
        while true {
            try Task.checkCancellation()
            guard token == generation else { throw CancellationError() }
            if deviceSession.state == .stopped {
                // Meta may publish the reason just after the stopped event.
                try await Task.sleep(for: .milliseconds(500))
                guard token == generation else { throw CancellationError() }
                if let sessionStartError { throw sessionStartError }
                throw DeviceSessionError.unexpectedError(description: "Device unavailable")
            }
            if let sessionStartError, deviceSession.state != .stopping {
                throw sessionStartError
            }
            if deviceSession.state == .started { break }
            guard ContinuousClock.now < startupDeadline else {
                if let sessionStartError { throw sessionStartError }
                throw DeviceError.message(connectionRecoveryMessage(wearables))
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        waitingForSessionStart = false
        return deviceSession
    }

    private func shouldRetrySessionStart(_ error: DeviceSessionError) -> Bool {
        switch error {
        case .noEligibleDevice, .sessionAlreadyExists, .dwaUnavailable: return true
        case .unexpectedError(let description):
            return description.localizedCaseInsensitiveContains("device unavailable")
        default: return false
        }
    }

    private func startStandbyCapabilities(_ deviceSession: DeviceSession, useSpeech: Bool, requireSpeech: Bool) async throws {
        let token = generation
        if let device = deviceSession.device {
            device.addDeviceStateListener { [weak self] state in Task { @MainActor in
                guard let self, self.generation == token else { return }
                if state.donState == .doffed || state.hingeState == .closed {
                    self.onUnavailable?("Put on your glasses to resume monitoring.")
                } else if [ThermalLevel.severe,.critical,.emergency,.shutdown].contains(state.thermalLevel) {
                    self.onUnavailable?("Let the glasses cool before arming again.")
                } else if (state.batteryLevel.map { $0 <= 5 } ?? false) {
                    self.onUnavailable?("Charge your glasses before arming again.")
                } else if state.linkState == .disconnected, device.linkState == .disconnected {
                    guard self.linkLossTask == nil else { return }
                    self.linkLossTask = Task { [weak self, weak device] in
                        do { try await Task.sleep(for: .seconds(4)) } catch { return }
                        guard let self, self.generation == token else { return }
                        self.linkLossTask = nil
                        guard device?.linkState == .disconnected else { return }
                        self.reportConnectionFailure("The glasses disconnected. Switch them off and on, put them on, and check the connection in Settings.")
                    }
                } else if state.linkState != .disconnected {
                    self.linkLossTask?.cancel()
                    self.linkLossTask = nil
                }
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
                        if self.motionSamplesReceived == 1 || self.motionSamplesReceived % 30 == 0 {
                            self.motionStatus = "Receiving \(String(describing: sample.source)) samples (\(self.motionSamplesReceived))"
                        }
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
                if requireSpeech { throw DeviceError.message("\(speechStatus) Enable Meta Speech capability and microphone permission, or choose iPhone local speech under Settings → Monitoring.") }
            }
        }
    }
    private func sessionErrorMessage(_ error: DeviceSessionError) -> String {
        if error == .datAppOnTheGlassesUpdateRequired {
            return "The glasses app needs an update. In Ray Guardian Settings, tap Update app on glasses."
        }
        if shouldRetrySessionStart(error) {
            return connectionRecoveryMessage(Wearables.shared)
        }
        return "Glasses session: \(error.localizedDescription)"
    }

    private func connectionRecoveryMessage(_ wearables: any WearablesInterface) -> String {
        let detected = wearables.devices.compactMap { wearables.deviceForIdentifier($0) }
        if let selected = selector?.activeDevice.flatMap({ wearables.deviceForIdentifier($0) }) ??
            detected.first(where: { $0.linkState == .connected }) {
            if selected.hingeState == .closed || selected.donState == .doffed {
                return "The glasses are connected and report that they aren’t being worn. Put them on and retry."
            }
            if selected.linkState == .connected {
                return "The glasses are connected, but Meta couldn’t start the Ray Guardian session. With the glasses on, check that Developer Mode is enabled for this pair in Meta AI, then retry."
            }
        }
        let summary = connectionSummary(wearables)
        return "\(summary). Switch the glasses off and on, put them on, and check that Meta AI shows them connected."
    }

    private func reportConnectionFailure(_ message: String) {
        if waitingForCameraFrame {
            if cameraStartupFailure == nil { cameraStartupFailure = message }
        } else {
            onUnavailable?(message)
        }
    }

    func updateGlassesApp() async throws {
        try requireConfiguration()
        try await Wearables.shared.openDATGlassesAppUpdate()
    }
    func startCapture(includeGlassesAudio: Bool, verifyFirstFrame: Bool = false, allowVideoWithoutAudio: Bool = false) async throws {
        try requireConfiguration()
        stopCapture(); let token = cameraGeneration
        try await waitForCameraStopped()
        guard let session, session.state == .started else { throw DeviceError.message("No started glasses session.") }
        guard try await Wearables.shared.checkPermissionStatus(.camera) == .granted else {
            throw DeviceError.message("Glasses connected. Allow camera access under Settings → Pairing and permissions.")
        }
        var audioEnabled = includeGlassesAudio
        if includeGlassesAudio, try await Wearables.shared.checkPermissionStatus(.microphone) != .granted {
            guard allowVideoWithoutAudio else { throw DeviceError.message("Glasses microphone permission required.") }
            audioEnabled = false
        }
        guard token == cameraGeneration, self.session === session, session.state == .started, !Task.isCancelled else { throw CancellationError() }
        let config = StreamConfiguration(videoCodec: .hvc1, audioCodec: audioEnabled ? .pcm(sampleRate: .rate16000, numberOfChannels: 1) : nil, resolution: .low, frameRate: Self.captureFrameRate)
        guard let attached = try session.addCamera(config: config) else { throw DeviceError.message("Camera unavailable.") }
        camera = attached
        waitingForCameraFrame = verifyFirstFrame
        let decoder = StreamImageDecoder(); imageDecoder = decoder
        attached.stream.videoFramePublisher.listen { [weak self] frame in
            guard let image = decoder.decode(frame.sampleBuffer) else { return }
            Task { @MainActor in
                guard let self, self.cameraGeneration == token else { return }
                self.receivedCameraFrame = true
                self.onFrame?(image)
            }
        }.store(in: cameraTokens)
        attached.stream.audioFramePublisher.listen { [weak self] frame in
            let arrivedAt = ProcessInfo.processInfo.systemUptime
            let pcm = PCMConverter.samples(frame.pcmBuffer)
            Task { @MainActor in guard self?.cameraGeneration == token else { return }; self?.onPCM?(pcm,arrivedAt) }
        }.store(in: cameraTokens)
        attached.stream.errorPublisher.listen { [weak self] error in Task { @MainActor in
            guard let self, self.cameraGeneration == token else { return }
            self.reportConnectionFailure(self.cameraErrorMessage(error))
        } }.store(in: cameraTokens)
        attached.stream.statePublisher.listen { [weak self] state in Task { @MainActor in guard self?.cameraGeneration == token else { return }; self?.cameraStatus = String(describing: state) } }.store(in: cameraTokens)
        attached.stream.start(); cameraStatus = "Starting bounded stream"
        if verifyFirstFrame {
            defer { if cameraGeneration == token { waitingForCameraFrame = false } }
            let deadline = ContinuousClock.now + .seconds(18)
            while true {
                try Task.checkCancellation()
                guard cameraGeneration == token else { throw CancellationError() }
                if let cameraStartupFailure { throw DeviceError.message(cameraStartupFailure) }
                if receivedCameraFrame { break }
                guard ContinuousClock.now < deadline else {
                    throw DeviceError.message("The glasses session opened, but no live video arrived. Keep the glasses on and retry the camera check.")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func cameraErrorMessage(_ error: StreamError) -> String {
        switch error {
        case .deviceNotFound, .deviceNotConnected, .timeout:
            return "The glasses camera lost its connection. Switch the glasses off and on, put them on, and retry."
        case .permissionDenied:
            return "Allow glasses camera access under Settings → Pairing and permissions."
        default:
            return "Glasses camera: \(error.localizedDescription)"
        }
    }

    func stopCapture() {
        cameraGeneration = UUID()
        waitingForCameraFrame = false
        receivedCameraFrame = false
        cameraStartupFailure = nil
        cameraTokens.clear()
        if let camera { stoppingCamera = camera; camera.stop() }
        camera = nil
        imageDecoder?.close()
        imageDecoder = nil
        cameraStatus = "Off"
    }
    func waitForCameraStopped() async throws {
        guard let camera = stoppingCamera else { return }
        let deadline = ProcessInfo.processInfo.systemUptime+2
        while camera.state != .stopped {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw DeviceError.message("The glasses camera is still stopping. Try again shortly.") }
            try await Task.sleep(for:.milliseconds(50))
        }
        if stoppingCamera === camera { stoppingCamera = nil }
    }
    var hasDisplay: Bool {
        guard let device = session?.device else { return false }
        return device.supportsDisplay() || device.deviceType() == .metaRayBanDisplay
    }

    func showMonitoring() {
        if displayPage == .controls { return }
        showDisplayPage(.monitoring)
    }

    func showCheckIn(id: String, deadline: Date, animation: IncidentAnimation.Presentation?) {
        showDisplayPage(.checkIn(id, deadline, animation))
    }

    func showDemoDispatch(_ dispatch: DemoDispatch, animation: IncidentAnimation.Presentation?) {
        showDisplayPage(.alert(dispatch, animation))
    }

    private func showDisplayPage(_ page: DisplayPage) {
        guard page != displayPage, let session, session.state == .started, hasDisplay else { return }
        displayPage = page
        let revision = UUID()
        displayRenderID = revision
        displayTask?.cancel()
        displayTask = Task { [weak self] in
            guard let self else { return }
            do {
                let screen = try self.display ?? session.addDisplay()
                self.display = screen
                self.startBandInput(session)
                if screen.state == .stopped { screen.start() }
                let limit = ContinuousClock.now + .seconds(5)
                while screen.state != .started, ContinuousClock.now < limit {
                    try await Task.sleep(for: .milliseconds(100))
                }
                try Task.checkCancellation()
                guard self.displayRenderID == revision else { return }
                guard screen.state == .started else { throw DeviceError.message("Display did not start.") }
                let animation = page.animation
                let reduceMotion = UIAccessibility.isReduceMotionEnabled
                // Send a short sequence of cards over DAT, then leave the last card in place.
                let finalFrame = 3.0
                let frames = [0.0, 0.6, 1.2, 1.8, 2.4, finalFrame]
                for frame in animation != nil && !reduceMotion ? frames : [finalFrame] {
                    try Task.checkCancellation()
                    guard self.displayRenderID == revision else { return }
                    let elapsed = animation?.elapsed(at: Date().timeIntervalSince1970) ?? IncidentAnimation.duration
                    if frame > 0, frame < elapsed, frame < finalFrame { continue }
                    let remaining = frame - elapsed
                    if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
                    let sample = reduceMotion ? IncidentAnimation.duration : max(frame, elapsed)
                    let art = animation.flatMap { IncidentDisplayArtwork.image(kind: $0.kind, elapsed: sample) }
                    let card = self.displayCard(for: page, revision: revision, artwork: art)
                    try await screen.send(card)
                    guard self.displayRenderID == revision else { return }
                    self.sentDisplayID = revision
                    self.displayStatus = "Active"
                    if sample >= finalFrame { break }
                }
            } catch {
                guard !Task.isCancelled, self.displayRenderID == revision else { return }
                self.displayPage = nil
                self.displayStatus = "Display unavailable: \(error.localizedDescription)"
            }
        }
    }

    private func displayCard(for page: DisplayPage, revision: UUID, artwork: UIImage?) -> FlexBox {
        let title: String, detail: String, button: String
        switch page {
        case .monitoring:
            (title, detail, button) = ("Ray Guardian", checkingConnection ? "Display and band test" : "Monitoring is on", "Controls")
        case .controls:
            let battery = session?.device?.batteryLevel.map { "Glasses battery \($0)%" } ?? "Pinch to return"
            (title, detail, button) = ("Guardian controls", battery, "Return")
        case .checkIn:
            (title, detail, button) = ("Are you okay?", "Calling for help if you don’t respond", "I’m okay")
        case .alert(let dispatch, _):
            let subtitle = dispatch.coordinates.map { "\(dispatch.destination) · \($0.displayText)" } ?? dispatch.destination
            (title, detail, button) = (dispatch.title, subtitle, "End call")
        }
        return FlexBox(direction: .column, spacing: 12) {
            MWDATDisplay.Text(title, style: .heading)
            MWDATDisplay.Text(detail)
            if let artwork {
                MWDATDisplay.Image(image: artwork, sizePreset: .fill, cornerRadius: .small).flexShrink(1)
            }
            MWDATDisplay.Button(label: button, onClick: { [weak self] in
                Task { @MainActor in
                    guard let self, self.displayRenderID == revision else { return }
                    self.selectDisplayPage()
                }
            }).actionRole(.primary)
        }.padding(24).background(.card)
    }

    private func selectDisplayPage() {
        let now = ProcessInfo.processInfo.systemUptime
        guard sentDisplayID == displayRenderID, now - lastDisplaySelect > 0.4 else { return }
        lastDisplaySelect = now
        switch displayPage {
        case .monitoring: showDisplayPage(.controls)
        case .controls: showDisplayPage(.monitoring)
        case .checkIn(let id, _, _): onDisplayCancel?(id)
        case .alert(let dispatch, _): onDisplayCancel?(dispatch.incidentID)
        case nil: break
        }
    }

    private func startBandInput(_ session: DeviceSession) {
        guard inputTask == nil else { return }
        do {
            guard let inputs = try session.addInputs(configuration: InputsConfiguration(
                sources: [.neuralBand], consumeBack: false
            )) else {
                bandStatus = "Unavailable"
                return
            }
            let token = generation
            bandStatus = "Waiting for a pinch"
            inputs.errorPublisher.listen { [weak self] error in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.bandStatus = "Unavailable: \(error.localizedDescription)"
                }
            }.store(in: inputTokens)
            inputTask = Task { [weak self] in
                for await event in inputs.events {
                    guard let self, !Task.isCancelled, self.generation == token else { break }
                    switch event {
                    case .select(source: .neuralBand, timestampMs: _):
                        self.bandStatus = "Pinch received"
                        self.selectDisplayPage()
                    default: break
                    }
                }
            }
        } catch {
            // Display buttons remain usable if raw Neural Band events are unavailable.
            bandStatus = "Unavailable"
        }
    }

    func stop() {
        generation = UUID()
        waitingForSessionStart = false
        sessionStartError = nil
        pauseTask?.cancel()
        pauseTask = nil
        linkLossTask?.cancel()
        linkLossTask = nil
        displayPage = nil
        displayRenderID = UUID()
        sentDisplayID = nil
        lastDisplaySelect = -Double.infinity
        inputTask?.cancel()
        inputTask = nil
        inputTokens.clear()
        if let session { try? session.removeInputs() }
        bandStatus = "Off"
        displayStatus = "Off"
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
        speechSuppressed = false
        speech?.stop()
        motion?.stop()
        if let session {
            if session.state != .stopped {
                session.stop()
                if session.state != .stopped { closingSession = session }
            }
        }
        speech = nil
        motion = nil
        session = nil
        selector = nil
        motionSamplesReceived = 0
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
