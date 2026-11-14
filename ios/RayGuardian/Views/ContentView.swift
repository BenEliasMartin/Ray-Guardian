import SwiftUI
import AVKit
import UniformTypeIdentifiers
import GuardianCore

struct ContentView: View {
    @ObservedObject var model: GuardianModel
    var body: some View {
        TabView {
            MonitorView(model: model).tabItem { Label("Guardian",systemImage: "shield.lefthalf.filled") }
            #if DEBUG
            ReplayView(model: model,library: model.replays,settings: model.settings).tabItem { Label("Mock glasses",systemImage: "eyeglasses") }
            #endif
            SettingsView(model: model,settings: model.settings).tabItem { Label("Setup",systemImage: "slider.horizontal.3") }
            HistoryView(model: model).tabItem { Label("Incidents",systemImage: "clock") }
        }.tint(.teal).alert("Action needs attention",isPresented: Binding(get: { model.error != nil },set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
struct MonitorView: View {
    @ObservedObject var model: GuardianModel
    @State private var showingGlassesView = false
    var body: some View {
        NavigationStack { ScrollView { VStack(alignment: .leading,spacing: 22) {
            Label("DEMONSTRATION · No emergency dispatch",systemImage: "info.circle").font(.caption.bold()).foregroundStyle(.orange)
            VStack(alignment: .leading,spacing: 8) {
                Text(model.armed ? "Guardian is armed" : "Your camera is off").font(.largeTitle.bold())
                Text(model.status).foregroundStyle(.secondary).accessibilityIdentifier("guardian.status")
            }
            if model.preview != nil || model.capturing || model.processing {
                GlassesPreview(model: model, showsOverlay: true)
                Button("Expand glasses preview", systemImage: "arrow.up.left.and.arrow.down.right") { showingGlassesView = true }
                    .buttonStyle(.bordered)
            }
            if let incident = model.incident { IncidentView(model: model,incident: incident) }
            HStack {
                Button { Task { await model.arm() } } label: { Label("Arm for 30 minutes",systemImage: "shield.checkered").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).disabled(model.armed || model.starting).accessibilityIdentifier("guardian.arm")
                Button("Stop",role: .destructive) { model.stop() }.buttonStyle(.bordered).accessibilityIdentifier("guardian.stop")
            }
            Button { model.sendTrigger(.manual_sos) } label: { Label("SOS · Start demo escalation",systemImage: "sos").font(.headline).frame(maxWidth: .infinity).padding(.vertical,12) }.buttonStyle(.borderedProminent).tint(.red).disabled(!model.armed)
            if model.armed && model.settings.consent.capture && model.settings.consent.cloud {
                Button("Check scene now", systemImage: "camera") { model.sendTrigger(.manual_check) }
                    .buttonStyle(.bordered).disabled(model.capturing || model.processing)
            }
            if model.capturing || model.processing {
                Text("\(model.frameCount)/6 frames · \(model.audioSeconds,specifier: "%.1f") seconds of audio")
                    .font(.callout).accessibilityIdentifier("guardian.frameCount")
            }
            if let detection = model.detection {
                GroupBox(detection.source == "nemotron" ? "Nemotron assessment" : "Assessment (\(detection.source))") { VStack(alignment: .leading,spacing: 8) {
                    Text(detection.label.replacingOccurrences(of: "_",with: " ").capitalized).font(.headline)
                    Text(detection.summary); Text(model.lastEvidence).font(.caption).accessibilityIdentifier("guardian.evidence"); Text("\(detection.confidence.capitalized) qualitative confidence").font(.caption).foregroundStyle(.secondary)
                    ForEach(detection.observations,id: \.self) { Label($0,systemImage: "eye").font(.callout) }
                    ForEach(detection.uncertainties,id: \.self) { Label($0,systemImage: "questionmark.circle").font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity,alignment: .leading) }
            }
            #if DEBUG
            Text("Last capture received \(model.debugLastCaptureFrames) SDK frames").font(.caption).accessibilityIdentifier("guardian.lastCaptureFrames")
            #endif
            DeviceStatusView(glasses: model.glasses,phone: model.phone,voice: model.voice,phoneMotion: model.phoneMotion)
            Text("Foreground rehearsal. Locking or leaving the app stops capture and local triggers. Optional background escalation continues only an existing demo incident on the server.").font(.caption).foregroundStyle(.secondary)
        }.controlSize(.large).padding() }.navigationTitle("Ray Guardian").toolbar { Button { Task { await model.refreshIncident() } } label: { Image(systemName: "arrow.clockwise") } } }
        .fullScreenCover(isPresented: $showingGlassesView) { GlassesPresentation(model: model) }
    }
}

struct GlassesPreview: View {
    @ObservedObject var model: GuardianModel
    let showsOverlay: Bool
    var fillsSpace = false

    private var haloState: QuietHalo.State? {
        QuietHalo.state(incidentState:model.incident?.state,transport:model.incident?.call?.transport,
                        capturing:model.capturing,processing:model.processing)
    }
    private var haloCountdown: QuietHalo.Countdown? {
        guard let incident=model.incident, let deadline=incident.checkInDeadline else { return nil }
        return QuietHalo.Countdown(startedAt:incident.createdAt,deadline:deadline)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .trailing) {
                Color(red: 0.04, green: 0.07, blue: 0.09)
                if let preview = model.preview {
                    Image(uiImage: preview).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped().accessibilityLabel("Camera feed")
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "camera").font(.largeTitle)
                        Text("Camera off until triggered").font(.headline)
                        Text("A speech or motion cue, SOS, or Check scene now starts up to eight seconds of capture")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.7))
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if showsOverlay {
                    QuietHaloView(state:haloState,incidentID:model.incident?.id,countdown:haloCountdown,updatedAt:model.incident?.updatedAt)
                        .frame(maxWidth:max(0,min(260,geometry.size.width-32)),alignment:.trailing)
                        .padding(16)
                        .frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.bottomTrailing)
                }
            }
            .overlay(alignment: .topLeading) {
                Text(showsOverlay ? "Simulated glasses display" : "Camera only")
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
                Text("Glasses view").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.bordered)
            }
            GlassesPreview(model: model, showsOverlay: true, fillsSpace: true)
            if model.incident?.terminal == false {
                Button { model.cancelIncident() } label: {
                    Text("I’m okay · Cancel demo").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .controlSize(.large)
    }
}

struct IncidentView: View {
    @ObservedObject var model: GuardianModel
    let incident: Incident
    var body: some View {
        GroupBox("Demo incident") { VStack(alignment: .leading,spacing: 12) {
            Text(incident.state.replacingOccurrences(of: "_",with: " ").capitalized).font(.title3.bold())
            if let deadline = incident.checkInDeadline, incident.state == "check_in" {
                CheckInCountdown(deadline: deadline).font(.title2.bold()).foregroundStyle(.orange)
                Text("Say ‘Guardian cancel’ or tap I’m okay.").font(.body)
            }
            Text(incident.triggerDescription).font(.caption)
            if let call = incident.call { Text("Demo call: \(call.transport) · \(call.status)").font(.callout) }
            if !incident.terminal {
                Button(role: .cancel) { model.cancelIncident() } label: {
                    Text("I’m okay · Cancel demo").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).controlSize(.large)
                if ["demo_call_active","call_queued","call_ringing","call_in_progress","call_completed"].contains(incident.state) { Button("Demo operator: acknowledge receipt") { Task { await model.acknowledge() } }.buttonStyle(.bordered) }
            }
            Text("No real responders are contacted. Telephone mode calls only the test destination configured on the server.").font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity,alignment: .leading) }
    }
}
struct DeviceStatusView: View {
    @ObservedObject var glasses: GlassesAdapter
    @ObservedObject var phone: PhoneAudio
    @ObservedObject var voice: VoicePlayer
    @ObservedObject var phoneMotion: PhoneMotion
    var body: some View { GroupBox("Device status") { VStack(alignment: .leading,spacing: 5) { Text(glasses.status); Text("Camera: \(glasses.cameraStatus)"); Text("Display: \(glasses.displayStatus)"); Text("Glasses motion: \(glasses.motionStatus)"); Text("Phone motion: \(phoneMotion.status)"); Text("Glasses speech: \(glasses.speechStatus)"); Text("Phone audio: \(phone.status)"); Text(voice.status); Text(voice.playing ? "Playing spoken cue" : "Voice idle") }.font(.caption).frame(maxWidth: .infinity,alignment: .leading) } }
}
struct GuardianAudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView,context: Context) {}
}
struct SettingsView: View {
    @ObservedObject var model: GuardianModel
    @ObservedObject var settings: Settings
    var body: some View {
        NavigationStack { Form {
            if model.armed || model.capturing || model.processing { Section { Text("Changing configuration immediately stops capture and disarms the session.") } }
            Section("Backend") {
                TextField("HTTPS API URL",text: $settings.apiURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                SecureField("Client token (not provider keys)",text: $settings.clientToken).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save and check connection") { Task { await model.checkBackend() } }
                if let health = model.health { Text("Nemotron \(health.providers["nemotron"]?.configured == true ? "configured" : "missing key") · ElevenLabs \(health.providers["elevenlabs"]?.configured == true ? "configured" : "missing key")"); Text("Demo dispatch: \(health.callTransport)") }
                Text("Client configuration is stored in Keychain. Verda, ElevenLabs and Twilio secrets stay on the backend.").font(.caption)
            }
            Section("Inputs") {
                #if DEBUG
                Picker("Device",selection: $settings.input) { ForEach(InputMode.allCases) { Text($0.rawValue).tag($0) } }
                #endif
                Picker("Keyword detector",selection: $settings.keywords) { ForEach(KeywordMode.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Capture audio",selection: $settings.audio) { ForEach(AudioMode.allCases.filter { settings.input == .mock || $0 != .replay }) { Text($0.rawValue).tag($0) } }
                Text("‘I’m in danger’, ‘I’m not safe’, ‘I can’t breathe’, ‘Help me’, ‘No, please don’t’, and spoken threats start a check-in. ‘Guardian SOS’ escalates the demo; ‘Guardian cancel’ cancels. A check-in does not depend on the camera seeing danger.").font(.caption)
                #if DEBUG
                if settings.input == .mock {
                    Toggle("Use iPhone motion for Mock testing",isOn: $settings.phoneMotionTesting)
                    Text("Phone free-fall followed by impact starts a check-in. It is labeled as phone motion and cannot confirm the wearer fell. Use Simulate events for a repeatable test.").font(.caption)
                }
                #endif
                Text("Glasses speech, motion and camera audio require the corresponding Meta developer capabilities. Phone speech requires downloaded on-device English recognition.").font(.caption)
            }
            if settings.input == .real {
                Section("Screenless glasses · audio setup") {
                    HStack {
                        Text("Choose glasses audio output")
                        Spacer()
                        GuardianAudioRoutePicker().frame(width:44,height:44)
                    }
                    Button("Test glasses audio") { model.testGlassesAudio() }.disabled(model.armed || model.starting)
                    Text(model.voice.status).font(.callout)
                    Text("Hear the test through your glasses before arming. DAT registration and Bluetooth audio output are separate. Check-ins use a short device-generated voice cue, so they do not wait for cloud speech.").font(.caption)
                    if settings.keywords == .off {
                        Text("Voice commands are off. Cancel and SOS require the iPhone controls.").font(.callout)
                    } else if settings.keywords == .phone {
                        Text("Commands use the iPhone microphone. Test with the phone where you will carry it; the glasses microphone is not used for recognition.").font(.caption)
                    }
                    Text("Keep Ray Guardian open and the iPhone unlocked during this rehearsal. Locking or leaving the app stops local monitoring.").font(.callout)
                }
            }
            Section("Per-session privacy choices") {
                Toggle("Allow triggered camera capture",isOn: $settings.consent.capture)
                Toggle("Allow bounded evidence sent to cloud AI",isOn: $settings.consent.cloud)
                Text("Camera and cloud transcription start only after an event or manual scene check. Local speech processes microphone input while armed; standby audio is not saved or uploaded.").font(.caption)
                Toggle("Include audio in cloud transcription",isOn: $settings.consent.audio)
                Toggle("Play spoken check-ins and demo audio",isOn: $settings.consent.voice)
                Toggle("Allow demo escalation / test calls",isOn: $settings.consent.demoCalls)
                Toggle("Share incident location",isOn: $settings.consent.location)
                Toggle("Continue existing demo escalation after leaving app",isOn: $settings.consent.backgroundEscalation)
                Text("Each capture lasts up to eight seconds and sends up to six images. Up to 12 triggered captures per ten minutes are allowed. Arming expires after 30 minutes. Changing these choices disarms the session. Encrypted incident metadata expires after 24 hours.").font(.caption)
            }
            Section("Optional Bluetooth heart-rate trigger") {
                Toggle("Use sustained high heart rate as an indicator",isOn:$settings.heartRateEnabled)
                Stepper("Threshold: \(settings.heartRateThreshold) bpm",value:$settings.heartRateThreshold,in:120...220,step:5)
                HeartRateSetup(sensor:model.heartRate)
                Text("A fresh sustained elevation can request a bounded assessment; heart rate never establishes an emergency. Exercise is a required negative control.").font(.caption)
            }
            Section("Real glasses setup") {
                Button("Grant phone microphone / local speech") { Task { do { try await model.phone.requestPermissions(localSpeech:settings.keywords == .phone) } catch { model.error = error.localizedDescription } } }
                Button("Grant incident location permission") { model.locator.requestPermission() }
                Button("Register with Meta AI") { Task { do { try await model.glasses.register() } catch { model.error = error.localizedDescription } } }
                Button("Grant glasses camera and microphone") { Task { do { try await model.glasses.requestPermissions() } catch { model.error = error.localizedDescription } } }
            }
        }.navigationTitle("Setup") }
    }
}
#if DEBUG
struct ReplayView: View {
    @ObservedObject var model: GuardianModel
    @ObservedObject var library: ReplayLibrary
    @ObservedObject var settings: Settings
    @State private var importing = false
    @State private var showsOverlay = true
    @State private var showingGlassesView = false
    var body: some View {
        NavigationStack { Form {
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
                Toggle("Use iPhone motion for Mock testing",isOn: $settings.phoneMotionTesting).disabled(model.armed)
                Text(settings.mockUsesReplay ? "Triggered camera source: selected replay" : "Triggered camera source: iPhone rear camera")
                Text(model.status).font(.headline)
                if !model.armed, settings.input == .mock {
                    Toggle("Allow camera capture",isOn: $settings.consent.capture)
                    Toggle("Allow cloud analysis",isOn: $settings.consent.cloud)
                    Toggle("Allow cloud audio",isOn: $settings.consent.audio)
                        .disabled(!settings.consent.cloud && !settings.consent.audio)
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
                    Button("Check scene now",systemImage: "camera") { model.sendTrigger(.manual_check) }.font(.headline)
                        .disabled(!settings.consent.capture || !settings.consent.cloud || model.capturing || model.processing)
                    Button("Stop mock session",role: .destructive) { model.stop() }.font(.headline)
                }
                if settings.input == .mock {
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
                Button("Simulate ‘I’m in danger’") { model.glasses.injectSpeech("I'm in danger") }.accessibilityIdentifier("guardian.injectDanger")
                Button("Simulate ‘No, please don’t’") { model.glasses.injectSpeech("No, please don't") }.accessibilityIdentifier("guardian.injectRefusal")
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
                    DeviceStatusView(glasses: model.glasses, phone: model.phone, voice: model.voice, phoneMotion: model.phoneMotion)
                }
            }
        }.navigationTitle("Mock glasses").navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented: $importing,allowedContentTypes: [.movie,.wav],allowsMultipleSelection: true) { result in do { try library.importFiles(result.get()) } catch { model.error = error.localizedDescription } }
        }
        .fullScreenCover(isPresented: $showingGlassesView) { GlassesPresentation(model: model) }
    }
}
#endif
struct HistoryView: View {
    @ObservedObject var model: GuardianModel
    var body: some View { NavigationStack { List { ForEach(model.history) { incident in VStack(alignment: .leading,spacing: 6) { Text(incident.detection?.summary ?? incident.triggerDescription); Text("\(incident.state.replacingOccurrences(of: "_",with: " ")) · \(Date(timeIntervalSince1970: incident.createdAt/1000).formatted())").font(.caption).foregroundStyle(.secondary) }.swipeActions { Button("Delete",role: .destructive) { Task { await model.deleteIncident(incident) } } } } }.overlay { if model.history.isEmpty { ContentUnavailableView("No retained incidents",systemImage: "clock",description: Text("Only encrypted metadata is retained for up to 24 hours.")) } }.navigationTitle("Incidents").refreshable { await model.loadHistory() }.task { await model.loadHistory() } } }
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
