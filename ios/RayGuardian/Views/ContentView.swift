import SwiftUI
import AVKit
import UniformTypeIdentifiers
import GuardianCore

private enum GuardianPalette {
    static let background = adaptive(light: 0xF8F7F3, dark: 0x191923)
    static let surface = adaptive(light: 0xFFFEFB, dark: 0x23232F)
    static let ink = adaptive(light: 0x26243B, dark: 0xF4F0F8)
    static let muted = adaptive(light: 0x625F72, dark: 0xC1BCCA)
    static let accent = adaptive(light: 0x554480, dark: 0xCDBBED)
    static let wash = adaptive(light: 0xEDE7F6, dark: 0x342A47)
    static let ring = adaptive(light: 0xD8CCE9, dark: 0x56436E)
    static let attention = adaptive(light: 0x794718, dark: 0xF0C496)
    static let attentionWash = adaptive(light: 0xF5E8D9, dark: 0x3E302A)
    static let verified = adaptive(light: 0x305F51, dark: 0xB1DCCB)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((rgb >> 16) & 255) / 255,
                green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255,
                alpha: 1
            )
        })
    }
}

private struct GuardianActionStyle: ButtonStyle {
    var prominent = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 54)
            .padding(.horizontal, 14)
            .foregroundStyle(prominent ? Color.white : GuardianPalette.accent)
            .background {
                RoundedRectangle(cornerRadius: 18)
                    .fill(prominent ? Color(red: 0.30, green: 0.23, blue: 0.47) : GuardianPalette.wash)
            }
            .contentShape(.interaction, RoundedRectangle(cornerRadius: 18))
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

private struct GuardianMark: View {
    let symbol: String
    var attention = false
    @ScaledMetric(relativeTo: .title) private var size = 152.0

    var body: some View {
        let diameter = min(size, 180)
        ZStack {
            Circle().strokeBorder(GuardianPalette.ring, lineWidth: 1)
            Circle().fill(attention ? GuardianPalette.attentionWash : GuardianPalette.wash)
                .padding(diameter * 0.10)
            Circle().strokeBorder(GuardianPalette.ring, lineWidth: 1)
                .padding(diameter * 0.20)
            Image(systemName: symbol)
                .font(.system(size: diameter * 0.23, weight: .regular))
                .foregroundStyle(attention ? GuardianPalette.attention : GuardianPalette.accent)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

struct ContentView: View {
    @ObservedObject var model: GuardianModel
    @State private var selectedTab = Tab.guardian

    private enum Tab { case guardian, incidents, settings, mock }
    private var activeIncidentID: String? {
        guard let incident = model.incident, !incident.terminal else { return nil }
        return incident.id
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            MonitorView(model: model)
                .tabItem { Label("Guardian", systemImage: "shield") }
                .tag(Tab.guardian)
            HistoryView(model: model)
                .tabItem { Label("Incidents", systemImage: "clock") }
                .tag(Tab.incidents)
            SettingsView(model: model, settings: model.settings, glasses: model.glasses)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
            #if DEBUG
            if model.settings.usesEphemeralUITestConfiguration {
                ReplayView(model: model, library: model.replays, settings: model.settings)
                    .tabItem { Label("Mock glasses", systemImage: "eyeglasses") }
                    .tag(Tab.mock)
            }
            #endif
        }
        .tint(GuardianPalette.accent)
        .onChange(of: activeIncidentID) { _, id in
            #if DEBUG
            if model.settings.usesEphemeralUITestConfiguration { return }
            #endif
            if id != nil { selectedTab = .guardian }
        }
    }
}

struct MonitorView: View {
    @ObservedObject var model: GuardianModel
    @ObservedObject private var settings: Settings
    @State private var showingGlassesView = false

    init(model: GuardianModel) {
        self.model = model
        self.settings = model.settings
    }

    private var title: String {
        if model.starting { return "Connecting to glasses" }
        return model.armed ? "Guardian is armed" : "Monitoring is off"
    }

    var body: some View {
        NavigationStack {
            GeometryReader { space in
                ScrollView {
                    VStack(spacing: 20) {
                        if let incident = model.incident, !incident.terminal {
                            IncidentView(model: model, incident: incident)
                        } else {
                            monitoring
                        }
                        if let error = model.error {
                            IssueBanner(message: error) { model.error = nil }
                        }
                        #if DEBUG
                        if settings.usesEphemeralUITestConfiguration { fixtureDiagnostics }
                        #endif
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 24)
                    .frame(maxWidth: 450)
                    .frame(minHeight: space.size.height)
                    .frame(maxWidth: .infinity)
                }
            }
            .background(GuardianPalette.background.ignoresSafeArea())
            .foregroundStyle(GuardianPalette.ink)
            .navigationTitle("Ray Guardian")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(GuardianPalette.background, for: .navigationBar, .tabBar)
            .toolbarBackground(.visible, for: .navigationBar, .tabBar)
            .toolbar {
                if model.armed, model.continuousCamera || model.preview != nil {
                    Button("Camera view", systemImage: "video") { showingGlassesView = true }
                } else if !model.armed, !model.starting, settings.input == .real, model.handGesturesActive {
                    Button("Practice gestures", systemImage: "hand.raised") {
                        model.setGesturePractice(.fist)
                        showingGlassesView = true
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showingGlassesView) { GlassesPresentation(model: model) }
    }

    private var monitoring: some View {
        VStack(spacing: 24) {
            GuardianMark(symbol: model.armed ? "checkmark.shield" : "shield")
            VStack(spacing: 9) {
                Text(title)
                    .font(.system(.largeTitle, design: .serif).weight(.medium))
                    .foregroundStyle(GuardianPalette.ink)
                    .accessibilityAddTraits(.isHeader)
                if model.starting {
                    Text("Keep your glasses on.")
                } else if model.armed, let until = model.session?.armedUntil {
                    Text("Armed until " + Date(timeIntervalSince1970: until / 1000).formatted(date: .omitted, time: .shortened))
                } else if let incident = model.incident, incident.terminal {
                    Text(incident.displayState)
                } else {
                    Text("Put on your glasses to begin.")
                }
            }
            .font(.subheadline)
            .foregroundStyle(GuardianPalette.muted)
            .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                if model.starting || model.armed {
                    Button(model.starting ? "Cancel connection" : "Disarm") { model.stop() }
                        .buttonStyle(GuardianActionStyle(prominent: false))
                        .accessibilityIdentifier("guardian.stop")
                } else {
                    Button("Arm for 30 minutes") { Task { await model.arm() } }
                        .buttonStyle(GuardianActionStyle())
                        .accessibilityIdentifier("guardian.arm")
                }
                if model.armed {
                    Button("Activate SOS") { model.sendTrigger(.manual_sos) }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(GuardianPalette.attention)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .buttonStyle(.plain)
                }
            }

            VStack(spacing: 7) {
                if model.armed, model.handGesturesActive {
                    Text("Hold a closed fist to start a check-in.")
                }
                if model.armed { Text("Keep this app open to stay armed.") }
            }
            .font(.footnote)
            .foregroundStyle(GuardianPalette.muted)
            .multilineTextAlignment(.center)
        }
    }

    #if DEBUG
    private var fixtureDiagnostics: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.status).accessibilityIdentifier("guardian.status")
            if !model.armed { Text("Your camera is off") }
            if model.capturing || model.processing {
                Text("\(model.frameCount)/6 frames").accessibilityIdentifier("guardian.frameCount")
            }
            if let detection = model.detection {
                Text("Assessment (\(detection.source))")
                Text(detection.summary)
                Text(model.lastEvidence).accessibilityIdentifier("guardian.evidence")
            }
            Text("Last capture received \(model.debugLastCaptureFrames) SDK frames")
                .accessibilityIdentifier("guardian.lastCaptureFrames")
        }
        .font(.caption)
    }
    #endif
}

struct IssueBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(GuardianPalette.attention)
                .accessibilityHidden(true)
            Text(message).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
            Button("Dismiss", systemImage: "xmark", action: dismiss).labelStyle(.iconOnly)
                .buttonStyle(.plain)
        }
        .padding(14)
        .background(GuardianPalette.attentionWash, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct GlassesPreview: View {
    @ObservedObject var model: GuardianModel
    let showsOverlay: Bool
    var fillsSpace = false
    var showWholeFrame = false

    private var displayState: (title: String, icon: String, color: Color) {
        if let id = model.audibleAlertID, id == model.incident?.id {
            return ("Alert active", "speaker.wave.2.fill", .orange)
        }
        switch model.incident?.state {
        case "check_in": return ("Are you okay?", "exclamationmark.triangle.fill", .orange)
        case "awaiting_foreground_confirmation": return ("Alert pending", "bell.badge", .orange)
        case "needs_demo_call_consent": return ("Alert paused", "pause.circle", .orange)
        case "demo_call_limited": return ("Alert limit reached", "pause.circle", .orange)
        case "call_queued", "call_ringing", "call_in_progress", "demo_call_active", "call_completed":
            return ("Alert active", "phone.fill", .orange)
        case "call_failed", "call_unknown": return ("Check alert", "exclamationmark.circle", .orange)
        default: break
        }
        if model.processing { return ("Analyzing scene", "sparkle.magnifyingglass", .cyan) }
        if model.capturing { return ("Checking scene", "viewfinder", .cyan) }
        if model.starting { return ("Connecting", "ellipsis.circle", .cyan) }
        if model.armed { return ("Guardian armed", "shield.fill", .mint) }
        return ("Guardian paused", "shield", .white)
    }

    var body: some View {
        GeometryReader { geometry in
            let state = displayState
            ZStack(alignment: .trailing) {
                Color(red: 0.04, green: 0.07, blue: 0.09)
                if let preview = model.preview {
                    Image(uiImage: preview).resizable().aspectRatio(contentMode: showWholeFrame ? .fit : .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped().accessibilityLabel("Camera feed")
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "camera").font(.largeTitle)
                        Text(model.continuousCamera ? "Waiting for camera" : "Camera preview").font(.headline)
                        Text(model.armed ? (model.continuousCamera ? "Waiting for the first frame" : "Frames appear during capture") : "Allow camera capture and arm to start")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if showsOverlay {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(state.title, systemImage: state.icon)
                            .font(.title3.bold())
                            .foregroundStyle(state.color)
                        if let incident = model.incident, incident.state == "check_in", let deadline = incident.checkInDeadline {
                            CheckInCountdown(deadline: deadline).font(.title.bold())
                            Text(model.handGesturesActive ? "Hold 🤙 or say “Guardian cancel”" : "Say “Guardian cancel”")
                                .font(.subheadline)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: min(270, geometry.size.width * 0.77), alignment: .leading)
                    .background(.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 16))
                    .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(state.color.opacity(0.55)) }
                    .padding(16)
                    .frame(maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .overlay(alignment: .topLeading) {
                Text(model.practiceGesture != nil ? "Glasses camera" : model.preview != nil && !model.continuousCamera && !model.capturing
                     ? "Last captured frame"
                     : (showsOverlay ? "Simulated glasses display" : "Camera only"))
                    .font(.callout.bold())
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.black.opacity(0.8), in: Capsule())
                    .padding(14)
            }
        }
        .foregroundStyle(.white)
        .frame(height: fillsSpace ? nil : 320)
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }
}

struct CheckInCountdown: View {
    let deadline: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let seconds = max(0, Int(ceil(deadline / 1000 - context.date.timeIntervalSince1970)))
            Text(seconds > 0 ? "\(seconds)s to respond" : "Checking status…")
                .monospacedDigit()
        }
    }
}

struct GlassesPresentation: View {
    @ObservedObject var model: GuardianModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Camera view").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.bordered)
            }
            GlassesPreview(model: model, showsOverlay: model.practiceGesture == nil, fillsSpace: true,
                           showWholeFrame: model.practiceGesture != nil)
            if model.incident?.terminal == false {
                Button { model.cancelIncident() } label: {
                    Text("I’m okay")
                }.buttonStyle(GuardianActionStyle())
            } else if let gesture = model.practiceGesture {
                Picker("Gesture", selection: Binding(
                    get: { model.practiceGesture ?? .fist },
                    set: { model.setGesturePractice($0) }
                )) {
                    Text("✊ Start").tag(HandGesture.fist)
                    Text("🤙 Cancel").tag(HandGesture.shaka)
                }.pickerStyle(.segmented)
                Text(practiceHint(for: gesture))
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("guardian.gesturePracticeStatus")
                Text("Practice won’t send an alert.").font(.footnote).foregroundStyle(.secondary)
            } else if let failure = model.practiceError {
                Text(failure).multilineTextAlignment(.center)
            } else if model.armed && model.handGesturesActive {
                Button("Practice gestures") { model.setGesturePractice(.fist) }
                    .buttonStyle(GuardianActionStyle(prominent: false))
            }
        }
        .padding()
        .background(GuardianPalette.background.ignoresSafeArea())
        .foregroundStyle(GuardianPalette.ink)
        .controlSize(.large)
        .onDisappear { model.setGesturePractice(nil) }
    }

    private func practiceHint(for gesture: HandGesture) -> String {
        switch model.gestureFeedback {
        case .waiting: return "Waiting for the glasses camera."
        case .noHand: return "Bring one whole hand into the center of the camera view."
        case .handVisible:
            return gesture == .fist ? "Hand visible. Close your fingers and tuck in your thumb."
                : "Hand visible. Face your palm toward the glasses and extend your thumb and pinky."
        case .holding: return "Gesture detected. Keep holding."
        case .recognized:
            return gesture == .fist ? "✊ Recognized" : "🤙 Recognized"
        case .unavailable: return "The camera is on, but hand recognition is unavailable."
        }
    }
}

private extension Incident {
    var displayState: String {
        switch state {
        case "check_in": return "Are you okay?"
        case "awaiting_foreground_confirmation": return "Alert pending"
        case "needs_demo_call_consent": return "Alert active"
        case "demo_call_limited": return "Alert limit reached"
        case "call_queued", "call_ringing": return "Alert pending"
        case "call_in_progress", "demo_call_active": return "Alert active"
        case "call_completed": return "Alert ended"
        case "call_failed", "call_unknown": return "Alert status unavailable"
        case "cancelled": return "Check-in cancelled"
        case "acknowledged": return "Alert acknowledged"
        default: return "Incident closed"
        }
    }
}

struct IncidentView: View {
    @ObservedObject var model: GuardianModel
    let incident: Incident

    var body: some View {
        VStack(spacing: 18) {
            GuardianMark(symbol: "bell", attention: true)
            Text(model.audibleAlertID == incident.id ? "Alert active" : incident.displayState)
                .font(.system(.largeTitle, design: .serif).weight(.medium))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("guardian.activeIncident")
            if let deadline = incident.checkInDeadline, incident.state == "check_in", model.audibleAlertID != incident.id {
                CheckInCountdown(deadline: deadline)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(GuardianPalette.attention)
            }
            if !incident.terminal {
                Button(incident.state == "check_in" && model.audibleAlertID != incident.id ? "I’m okay" : "Silence alert") {
                    model.cancelIncident()
                }
                .buttonStyle(GuardianActionStyle())
                if model.armed {
                    Text(model.handGesturesActive
                        ? (model.gestureFeedback == .holding ? "🤙 Detected. Keep holding." : "Or hold 🤙 in front of your glasses or say “Guardian cancel.”")
                        : "Or say “Guardian cancel.”")
                        .font(.footnote)
                        .foregroundStyle(GuardianPalette.muted)
                }
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}

struct DeviceStatusView: View {
    @ObservedObject var glasses: GlassesAdapter
    @ObservedObject var phone: PhoneAudio
    @ObservedObject var voice: VoicePlayer
    var body: some View { GroupBox("Device status") { VStack(alignment: .leading,spacing: 5) { Text(glasses.status); Text("Camera: \(glasses.cameraStatus)"); Text("Display: \(glasses.displayStatus)"); Text("Neural Band: \(glasses.bandStatus)"); Text("Motion: \(glasses.motionStatus)"); Text("Glasses speech: \(glasses.speechStatus)"); Text("Phone audio: \(phone.status)"); Text(voice.playing ? "Playing spoken audio" : "Voice idle") }.font(.caption).frame(maxWidth: .infinity,alignment: .leading) } }
}
struct SettingsView: View {
    @ObservedObject var model: GuardianModel
    @ObservedObject var settings: Settings
    @ObservedObject var glasses: GlassesAdapter

    private var changingConnection: Bool {
        model.armed || model.starting || model.practiceGesture != nil || glasses.checkingConnection || glasses.requestingPermission
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error = model.error {
                    Section { IssueBanner(message: error) { model.error = nil } }
                }
                Section("Glasses") {
                    Picker("Glasses pair", selection: Binding(
                        get: { glasses.preferredGlassesID },
                        set: { glasses.chooseGlasses($0) }
                    )) {
                        Text("Automatic").tag(nil as String?)
                        ForEach(glasses.availableGlasses) { pair in
                            Text(pair.hasDisplay ? "\(pair.name) · Display" : pair.name).tag(Optional(pair.id))
                        }
                        if let id = glasses.preferredGlassesID, !glasses.availableGlasses.contains(where: { $0.id == id }) {
                            Text("Selected pair unavailable").tag(Optional(id))
                        }
                    }
                    .disabled(changingConnection)
                    Button("Check glasses connection", systemImage: "eyeglasses") {
                        Task { await model.checkGlassesConnection() }
                    }
                    .disabled(changingConnection)
                    if glasses.availableGlasses.contains(where: { $0.hasDisplay &&
                        (glasses.preferredGlassesID == nil || glasses.preferredGlassesID == $0.id) }) {
                        Button("Test glasses display", systemImage: "rectangle.inset.filled") {
                            Task { await glasses.testDisplay() }
                        }
                        .disabled(changingConnection)
                    }
                    if glasses.checkingConnection {
                        ProgressView(glasses.status)
                        if glasses.bandStatus != "Off" {
                            Text("Neural Band: \(glasses.bandStatus)").font(.footnote).foregroundStyle(.secondary)
                        }
                    } else if !glasses.permissionStatus.isEmpty {
                        Text(glasses.permissionStatus).font(.footnote).foregroundStyle(.secondary)
                    }
                    if glasses.glassesAppUpdateRequired {
                        Button("Update app on glasses") {
                            Task { await perform { try await glasses.updateGlassesApp() } }
                        }
                        .disabled(changingConnection)
                    }
                    NavigationLink("Pairing and permissions") { permissions }
                }
                Section {
                    NavigationLink {
                        monitoringPreferences
                    } label: {
                        Label("Monitoring", systemImage: "waveform")
                    }
                    NavigationLink {
                        privacyPreferences
                    } label: {
                        Label("Privacy", systemImage: "lock")
                    }
                }
                Section {
                    NavigationLink("Advanced settings") { advanced }
                } footer: {
                    if model.armed { Text("Changing a setting disarms Guardian.") }
                }
            }
            .scrollContentBackground(.hidden)
            .background(GuardianPalette.background.ignoresSafeArea())
            .navigationTitle("Settings")
            .task { await glasses.observeGlasses() }
            .toolbarBackground(GuardianPalette.background, for: .navigationBar, .tabBar)
            .toolbarBackground(.visible, for: .navigationBar, .tabBar)
        }
    }

    private var monitoringPreferences: some View {
        Form {
            Section {
                Toggle("Use glasses camera", isOn: $settings.consent.capture)
                Toggle("Recognize hand gestures", isOn: $settings.handGestures)
                    .disabled(!settings.consent.capture)
                Toggle("Listen for spoken distress", isOn: $settings.elevenLabsListening)
                    .disabled((!settings.consent.audio || !settings.consent.cloud) && !settings.elevenLabsListening)
                Toggle("Speak check-ins on glasses", isOn: $settings.speakWithoutDisplay)
            } footer: {
                Text("Hold a fist to start a check-in, or hold 🤙 with your thumb and pinky out to cancel. Hold either for about a second.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(GuardianPalette.background.ignoresSafeArea())
        .navigationTitle("Monitoring")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var privacyPreferences: some View {
        Form {
            Section {
                Toggle("Record sound in incident clips", isOn: $settings.recordClipAudio)
                    .disabled(!settings.consent.capture)
                Toggle("Allow cloud analysis", isOn: Binding(
                    get: { settings.consent.cloud },
                    set: { enabled in
                        if !enabled {
                            settings.elevenLabsListening = false
                            settings.consent.audio = false
                        }
                        settings.consent.cloud = enabled
                    }
                ))
                Toggle("Include audio in cloud analysis", isOn: Binding(
                    get: { settings.consent.audio },
                    set: { enabled in
                        if !enabled { settings.elevenLabsListening = false }
                        settings.consent.audio = enabled
                    }
                ))
                .disabled(!settings.consent.cloud)
                Toggle("Share location during an incident", isOn: $settings.consent.location)
            } footer: {
                Text("Incident clips stay on this iPhone for up to 24 hours. Cloud audio sharing is a separate choice.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(GuardianPalette.background.ignoresSafeArea())
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var permissions: some View {
        Form {
            Section {
                Button("Connect through Meta AI") { Task { await perform { try await glasses.register() } } }
                Button("Allow glasses camera") { Task { await perform { try await glasses.grantCameraPermission() } } }
                Button("Allow glasses microphone") { Task { await perform { try await glasses.grantMicrophonePermission() } } }
            }
            .disabled(changingConnection)
            Section {
                Button("Allow iPhone microphone and speech recognition") {
                    Task { await perform { try await model.phone.requestPermissions(localSpeech: true) } }
                }
                Button("Allow location") { model.locator.requestPermission() }
            }
            if glasses.requestingPermission { ProgressView(glasses.permissionStatus) }
            else if !glasses.permissionStatus.isEmpty { Text(glasses.permissionStatus).font(.footnote) }
            if let error = model.error { IssueBanner(message: error) { model.error = nil } }
        }
        .scrollContentBackground(.hidden)
        .background(GuardianPalette.background.ignoresSafeArea())
        .navigationTitle("Pairing and permissions")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var advanced: some View {
        Form {
            Section("Monitoring options") {
                Toggle("Automatically check the scene", isOn: $settings.automaticSceneChecks)
                    .disabled(!settings.consent.capture || !settings.consent.cloud)
                Toggle("Keep the camera preview live", isOn: $settings.preTriggerFrames)
                    .disabled(!settings.consent.capture)
                Button("Test alert tone") { model.playAlertTone() }.disabled(model.armed || model.starting)
                Button("Test spoken check-in") { model.playSpokenCheckIn() }.disabled(model.armed || model.starting)
                Picker("Local speech", selection: $settings.keywords) {
                    ForEach(KeywordMode.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Capture microphone", selection: $settings.audio) {
                    ForEach(AudioMode.allCases.filter { settings.input == .mock || $0 != .replay }) { Text($0.rawValue).tag($0) }
                }
            }
            Section("Heart rate") {
                Toggle("Use heart-rate sensor", isOn: $settings.heartRateEnabled)
                if settings.heartRateEnabled {
                    Stepper("Threshold: \(settings.heartRateThreshold) bpm", value: $settings.heartRateThreshold, in: 120...220, step: 5)
                    HeartRateSetup(sensor: model.heartRate)
                }
            }
            Section("Service connection") {
                TextField("Service URL", text: $settings.apiURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                SecureField("Access token", text: $settings.clientToken)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save and check service") { Task { await model.checkBackend() } }
                if let health = model.health {
                    Text(health.ready ? "Service is ready" : "Some service features are unavailable")
                }
            }
            Section("Troubleshooting") {
                if let error = model.error { IssueBanner(message: error) { model.error = nil } }
                DeviceStatusView(glasses: glasses, phone: model.phone, voice: model.voice)
                #if DEBUG
                Picker("Input", selection: $settings.input) {
                    ForEach(InputMode.allCases) { Text($0.rawValue).tag($0) }
                }
                NavigationLink("Mock glasses") {
                    ReplayView(model: model, library: model.replays, settings: settings, embedded: true)
                }
                #endif
            }
        }
        .scrollContentBackground(.hidden)
        .background(GuardianPalette.background.ignoresSafeArea())
        .navigationTitle("Advanced settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func perform(_ action: () async throws -> Void) async {
        model.error = nil
        do { try await action() }
        catch { model.error = error.localizedDescription }
    }
}
#if DEBUG
struct ReplayView: View {
    @ObservedObject var model: GuardianModel
    @ObservedObject var library: ReplayLibrary
    @ObservedObject var settings: Settings
    @State private var importing = false
    var embedded = false
    @State private var showsOverlay = true
    @State private var showingGlassesView = false
    var body: some View {
        Group {
            if embedded { controls }
            else { NavigationStack { controls } }
        }
        .fullScreenCover(isPresented: $showingGlassesView) { GlassesPresentation(model: model) }
    }

    private var controls: some View {
        Form {
            Section {
                GlassesPreview(model: model, showsOverlay: showsOverlay)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                Picker("Preview view", selection: $showsOverlay) {
                    Text("Glasses overlay").tag(true)
                    Text("Camera only").tag(false)
                }.pickerStyle(.segmented)
                Button("Expand glasses preview", systemImage: "arrow.up.left.and.arrow.down.right") {
                    showingGlassesView = true
                }.font(.headline)
            }
            if let incident = model.incident, settings.input == .mock {
                Section { IncidentView(model: model, incident: incident) }
            }
            Section("Mock session") {
                Toggle("Use video replay",isOn: $settings.mockUsesReplay).disabled(model.armed)
                Text(settings.mockUsesReplay ? "Camera source: selected replay" : "Camera source: live iPhone rear camera")
                Text(model.status).font(.headline)
                if !model.armed, settings.input == .mock {
                    Toggle("Allow camera capture",isOn: $settings.consent.capture)
                    Toggle("Allow cloud analysis",isOn: $settings.consent.cloud)
                    Toggle("Allow cloud audio",isOn: $settings.consent.audio)
                        .disabled(!settings.consent.cloud && !settings.consent.audio)
                    Toggle("ElevenLabs listening while armed",isOn: $settings.elevenLabsListening)
                        .disabled((!settings.consent.audio || !settings.consent.cloud) && !settings.elevenLabsListening)
                    Toggle("Automatically check the scene",isOn: $settings.automaticSceneChecks)
                        .disabled(!settings.consent.capture || !settings.consent.cloud)
                }
                if !model.armed {
                    if settings.input == .mock {
                        Button { Task { await model.arm() } } label: {
                            Label("Arm mock glasses", systemImage: "shield.checkered").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.starting)
                    } else {
                        Button("Switch to mock glasses") { settings.input = .mock }
                    }
                } else if settings.input == .mock {
                    Button("Check scene now",systemImage: "camera") { model.sendTrigger(.scene_check) }.font(.headline)
                        .disabled(!settings.automaticSceneChecks || !settings.consent.capture || !settings.consent.cloud || model.capturing || model.processing)
                    Button("Stop mock session",role: .destructive) { model.stop() }.font(.headline)
                }
                if settings.input == .mock {
                    if settings.elevenLabsListening { Text("ElevenLabs · \(model.cloudSpeechStatus)").font(.callout) }
                    if model.capturing || model.processing {
                        ProgressView(model.capturing ? "Capturing evidence" : "Nemotron processing")
                        Text("\(model.frameCount)/6 frames").font(.callout)
                    }
                }
            }
            if let detection = model.detection, settings.input == .mock {
                Section("Latest assessment") {
                    Text(detection.label.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.title3.bold())
                    Text(detection.summary)
                    Text(model.lastEvidence).font(.callout).foregroundStyle(.secondary)
                }
            }
            if settings.mockUsesReplay {
            Section("Wearer-POV media") {
                Text(library.status).font(.callout)
                Picker("Replay",selection: $library.selectedID) { Text("Select clip").tag(Optional<String>.none); ForEach(library.clips) { Text($0.title).tag(Optional($0.id)) } }
                if let clip = library.selected { Text("Reference label: \(clip.expected ?? "unlabeled"). This label and filename are never sent to Nemotron.").font(.caption); if let attribution = clip.attribution { Text(attribution).font(.caption) } }
                Button("Fetch replay index from backend") { Task { do { try await library.sync(api: model.makeAPI()) } catch { model.error = error.localizedDescription } } }
                Button("Download selected media") { Task { do { try await library.downloadSelected(api: model.makeAPI()) } catch { model.error = error.localizedDescription } } }
                Button("Import HEVC video / mono 16 kHz WAV") { importing = true }
                Button("Clear downloaded replay cache",role: .destructive) { do { try library.clearCache() } catch { model.error = error.localizedDescription } }
            }.disabled(model.armed)
            }
            Section("iPhone as the glasses motion sensor") {
                Toggle("Use iPhone accelerometer and gyroscope for fall tests",isOn: $settings.phoneMotionTesting)
                    .accessibilityIdentifier("guardian.phoneMotion")
                Text("Stands in for the Meta glasses IMU in Mock mode: the same free-fall, rapid-tilt and slow-collapse detection runs on the iPhone's motion, and its motion summary goes to Nemotron. Hold the phone at head height or strap it to a helmet, and drop it only onto something soft. \(model.phoneMotion.status)").font(.caption)
            }.disabled(model.armed)
            Section("Simulate events · arm first") {
                Button("Simulate spoken threat") { model.glasses.injectSpeech("I’m going to kill you") }
                Button("Inject ‘Guardian help me’") { model.glasses.injectSpeech("Guardian help me") }.accessibilityIdentifier("guardian.injectDistress")
                Button("Replay free-fall and impact samples") { model.replayMotion() }.accessibilityIdentifier("guardian.injectMotion")
                Button("Inject ‘Guardian cancel’") { model.glasses.injectSpeech("Guardian cancel") }.accessibilityIdentifier("guardian.injectCancel")
                Button("Inject ‘Guardian SOS’") { model.glasses.injectSpeech("Guardian SOS") }
                Text("Events pass through SDK listeners and the same local detectors as real streams. Replay WAV is paced through the PCM pipeline because MockDeviceKit has no public PCM injection API.").font(.caption)
            }.disabled(!model.armed || settings.input != .mock)
            Section("Failure rehearsal") {
                Button("Disconnect mock glasses") { model.glasses.mockFault("disconnect") }
                Button("Remove mock glasses") { model.glasses.mockFault("doff") }
                Button("Simulate thermal limit") { model.glasses.mockFault("thermal") }
                Button("Revoke mock camera permission") { model.glasses.mockFault("permission") }
            }.disabled(!model.armed || settings.input != .mock)
            Section {
                DisclosureGroup("Device diagnostics") {
                    DeviceStatusView(glasses: model.glasses, phone: model.phone, voice: model.voice)
                }
            }
        }.navigationTitle("Mock glasses").navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented: $importing,allowedContentTypes: [.movie,.wav],allowsMultipleSelection: true) { result in do { try library.importFiles(result.get()) } catch { model.error = error.localizedDescription } }
    }
}
#endif
struct HistoryView: View {
    @ObservedObject var model: GuardianModel
    @State private var pendingDelete: Incident?

    var body: some View {
        NavigationStack {
            Group {
                if model.history.isEmpty {
                    emptyHistory
                } else {
                    List(model.history) { incident in
                        NavigationLink {
                            IncidentReviewView(model: model, incident: incident)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(incident.displayState)
                                    .font(.headline).foregroundStyle(GuardianPalette.ink)
                                Text(Date(timeIntervalSince1970: incident.createdAt / 1000), format: .dateTime)
                                    .font(.subheadline).foregroundStyle(GuardianPalette.muted)
                            }
                            .padding(.vertical, 8)
                        }
                        .listRowBackground(GuardianPalette.surface)
                        .swipeActions(allowsFullSwipe: false) {
                            Button("Delete", systemImage: "trash", role: .destructive) { pendingDelete = incident }
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                    .refreshable { await model.loadHistory() }
                }
            }
            .background(GuardianPalette.background.ignoresSafeArea())
            .navigationTitle("Incidents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(GuardianPalette.background, for: .navigationBar, .tabBar)
            .toolbarBackground(.visible, for: .navigationBar, .tabBar)
            .task { await model.loadHistory() }
            .confirmationDialog("Delete this incident and its recording?", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
            ), titleVisibility: .visible) {
                if let item = pendingDelete {
                    Button("Delete incident", role: .destructive) { Task { await model.deleteIncident(item) } }
                }
            }
        }
    }

    private var emptyHistory: some View {
        ScrollView {
            VStack(spacing: 18) {
                GuardianMark(symbol: model.historyError ? "wifi.exclamationmark" : "clock")
                Text(model.historyError ? "Couldn’t load incidents" : "No recent incidents")
                    .font(.system(.title, design: .serif).weight(.medium))
                    .foregroundStyle(GuardianPalette.ink)
                    .accessibilityAddTraits(.isHeader)
                if model.historyError {
                    Button("Try again") { Task { await model.loadHistory() } }
                        .buttonStyle(GuardianActionStyle(prominent: false))
                } else {
                    Text("Recordings are kept for up to 24 hours.")
                        .font(.subheadline)
                        .foregroundStyle(GuardianPalette.muted)
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
            .padding(.vertical, 64)
            .frame(maxWidth: 450)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await model.loadHistory() }
    }
}

struct IncidentReviewView: View {
    @ObservedObject var model: GuardianModel
    let incident: Incident
    @State private var evidence: ReviewedEvidence?
    @State private var player: AVPlayer?
    @State private var clipHasAudio = false
    @State private var showVerification = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(incident.displayState)
                    .font(.system(.largeTitle, design: .serif).weight(.medium))
                    .foregroundStyle(GuardianPalette.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(Date(timeIntervalSince1970: incident.createdAt / 1000), format: .dateTime)
                    .font(.subheadline).foregroundStyle(GuardianPalette.muted)
                media
                if let assessment = incident.detection?.summary {
                    Text(assessment).foregroundStyle(GuardianPalette.muted)
                }
            }
            .frame(maxWidth: 550, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .background(GuardianPalette.background.ignoresSafeArea())
        .navigationTitle("Incident")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: incident.id) {
            let result = await model.reviewEvidence(for: incident)
            guard !Task.isCancelled else { return }
            if case .clip(let url) = result {
                let asset = AVURLAsset(url: url)
                clipHasAudio = (try? await asset.loadTracks(withMediaType: .audio).isEmpty) == false
                guard !Task.isCancelled else { return }
                player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            }
            evidence = result
        }
        .onDisappear { player?.pause() }
        .alert("Verified on this iPhone", isPresented: $showVerification) {
            Button("Done", role: .cancel) {}
        } message: {
            Text("Ray Guardian checked the signature and confirmed the file matches what this iPhone originally saved.")
        }
    }

    @ViewBuilder
    private var media: some View {
        switch evidence {
        case .clip:
            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(4.0 / 3.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("Saved incident clip")
            }
            verificationBadge
            Text(clipHasAudio ? "Clip with audio · Saved on this iPhone" : "Silent clip · Saved on this iPhone")
                .font(.caption).foregroundStyle(.secondary)
        case .photo(let data, let verified):
            if let photo = UIImage(data: data) {
                Image(uiImage: photo).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("Saved incident photo")
                if verified { verificationBadge }
                else { Label("Photo saved before verification was available", systemImage: "photo").font(.footnote) }
            } else {
                Label("Photo couldn't be opened", systemImage: "photo")
            }
        case .integrityFailed:
            Label("This recording couldn't be verified", systemImage: "exclamationmark.shield")
                .foregroundStyle(.orange)
        case .unavailable:
            Label("No recording saved on this iPhone", systemImage: "video.slash")
                .foregroundStyle(.secondary)
        case nil:
            ProgressView("Checking incident recording…")
        }
    }

    private var verificationBadge: some View {
        Button {
            showVerification = true
        } label: {
            Label("Cryptographically verified", systemImage: "checkmark.shield.fill")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(GuardianPalette.verified)
        .accessibilityHint("Shows what was verified")
    }
}

struct HeartRateSetup: View {
    @ObservedObject var sensor: HeartRateMonitor
    var body: some View { VStack(alignment:.leading) {
        Text(sensor.status); if let bpm = sensor.bpm { Text("\(bpm) bpm") }
        Button("Scan Bluetooth heart-rate sensors") { sensor.scan() }
        ForEach(sensor.sensors) { item in Button("Connect \(item.name)") { sensor.connect(item) } }
        Button("Disconnect sensor") { sensor.stop() }
    } }
}
