import SwiftUI
import UniformTypeIdentifiers
import GuardianCore

struct ContentView: View {
    @ObservedObject var model: GuardianModel
    var body: some View {
        TabView {
            MonitorView(model: model).tabItem { Label("Guardian",systemImage: "shield.lefthalf.filled") }
            ReplayView(model: model,library: model.replays).tabItem { Label("Replay lab",systemImage: "play.rectangle") }
            SettingsView(model: model,settings: model.settings).tabItem { Label("Setup",systemImage: "slider.horizontal.3") }
            HistoryView(model: model).tabItem { Label("Incidents",systemImage: "clock") }
        }.tint(.teal).alert("Action needs attention",isPresented: Binding(get: { model.error != nil },set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}
struct MonitorView: View {
    @ObservedObject var model: GuardianModel
    var body: some View {
        NavigationStack { ScrollView { VStack(alignment: .leading,spacing: 22) {
            Label("DEMONSTRATION · No emergency dispatch",systemImage: "info.circle").font(.caption.bold()).foregroundStyle(.orange)
            VStack(alignment: .leading,spacing: 8) {
                Text(model.armed ? "Guardian is armed" : "Your camera is off").font(.largeTitle.bold())
                Text(model.status).foregroundStyle(.secondary).accessibilityIdentifier("guardian.status")
                Text("Local motion and selected speech can trigger an eight-second capture. There is no pre-event video buffer.").font(.callout)
            }
            HStack {
                Button { Task { await model.arm() } } label: { Label("Arm for 30 minutes",systemImage: "shield.checkered").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).disabled(model.armed)
                Button("Stop",role: .destructive) { model.stop() }.buttonStyle(.bordered)
            }
            Button { model.sendTrigger(.manual_sos) } label: { Label("SOS · Start demo escalation",systemImage: "sos").font(.headline).frame(maxWidth: .infinity).padding(.vertical,12) }.buttonStyle(.borderedProminent).tint(.red).disabled(!model.armed)
            if model.capturing || model.processing {
                GroupBox { VStack(alignment: .leading) { ProgressView(model.capturing ? "Bounded capture active" : "Nemotron processing"); Text("\(model.frameCount)/6 frames · \(model.audioSeconds,specifier: "%.1f") seconds of audio").font(.caption).accessibilityIdentifier("guardian.frameCount"); if let preview = model.preview { Image(uiImage: preview).resizable().scaledToFit().frame(maxHeight: 220).accessibilityLabel("Current in-memory wearer frame") } } }
            }
            if let detection = model.detection {
                GroupBox(detection.source == "nemotron" ? "Nemotron assessment" : "Assessment (\(detection.source))") { VStack(alignment: .leading,spacing: 8) {
                    Text(detection.label.replacingOccurrences(of: "_",with: " ").capitalized).font(.headline)
                    Text(detection.summary); Text(model.lastEvidence).font(.caption).accessibilityIdentifier("guardian.evidence"); Text("\(detection.confidence.capitalized) qualitative confidence").font(.caption).foregroundStyle(.secondary)
                    ForEach(detection.observations,id: \.self) { Label($0,systemImage: "eye").font(.callout) }
                    ForEach(detection.uncertainties,id: \.self) { Label($0,systemImage: "questionmark.circle").font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity,alignment: .leading) }
            }
            if let incident = model.incident { IncidentView(model: model,incident: incident) }
            #if DEBUG
            Text("Last capture received \(model.debugLastCaptureFrames) SDK frames").font(.caption).accessibilityIdentifier("guardian.lastCaptureFrames")
            #endif
            DeviceStatusView(glasses: model.glasses,phone: model.phone,voice: model.voice)
            Text("Foreground rehearsal. Locking or leaving the app stops capture and local triggers. Optional background escalation continues only an existing demo incident on the server.").font(.caption).foregroundStyle(.secondary)
        }.padding() }.navigationTitle("Ray Guardian").toolbar { Button { Task { await model.refreshIncident() } } label: { Image(systemName: "arrow.clockwise") } } }
    }
}
struct IncidentView: View {
    @ObservedObject var model: GuardianModel
    let incident: Incident
    var body: some View {
        GroupBox("Demo incident") { VStack(alignment: .leading,spacing: 12) {
            Text(incident.state.replacingOccurrences(of: "_",with: " ").capitalized).font(.title3.bold())
            if let deadline = incident.checkInDeadline, incident.state == "check_in" { Text("Check-in deadline: \(Date(timeIntervalSince1970: deadline/1000),style: .time)"); Text("Say ‘Guardian cancel’ or press I’m okay to stop the demonstration.") }
            Text(incident.detectedBy == "nemotron" ? "Evidence assessed by Nemotron" : "Wearer initiated SOS; awaiting optional Nemotron evidence").font(.caption)
            if let call = incident.call { Text("Demo call: \(call.transport) · \(call.status)").font(.callout) }
            if !incident.terminal {
                Button("I’m okay · Cancel demo",role: .cancel) { model.cancelIncident() }.buttonStyle(.borderedProminent)
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
    var body: some View { GroupBox("Device status") { VStack(alignment: .leading,spacing: 5) { Text(glasses.status); Text("Camera: \(glasses.cameraStatus)"); Text("Motion: \(glasses.motionStatus)"); Text("Glasses speech: \(glasses.speechStatus)"); Text("Phone audio: \(phone.status)"); Text(voice.playing ? "Playing ElevenLabs voice" : "Voice idle") }.font(.caption).frame(maxWidth: .infinity,alignment: .leading) } }
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
                Text("Wake phrases: ‘Guardian help me’ starts assessment. ‘Guardian SOS’ or ‘Guardian call for help’ explicitly escalates the demo. ‘Guardian cancel’ cancels. Loudness alone never starts capture.").font(.caption)
                Text("Glasses speech, motion and camera audio require the corresponding Meta developer capabilities. Phone speech requires downloaded on-device English recognition.").font(.caption)
            }
            Section("Per-session privacy choices · off by default") {
                Toggle("Allow triggered camera capture",isOn: $settings.consent.capture)
                Toggle("Allow bounded evidence sent to cloud AI",isOn: $settings.consent.cloud)
                Toggle("Automatically check the scene while armed",isOn: $settings.automaticSceneChecks)
                    .disabled(!settings.consent.capture || !settings.consent.cloud)
                Text("Scene checks take short camera samples without a voice or fall cue. The shared capture limit leaves gaps between checks.").font(.caption)
                Toggle("Include audio in cloud transcription",isOn: $settings.consent.audio)
                Toggle("Play real ElevenLabs voice",isOn: $settings.consent.voice)
                Toggle("Allow demo escalation / test calls",isOn: $settings.consent.demoCalls)
                Toggle("Share incident location",isOn: $settings.consent.location)
                Toggle("Continue existing demo escalation after leaving app",isOn: $settings.consent.backgroundEscalation)
                Text("Camera opens only for an accepted indicator: at most eight seconds, six images and three bursts per ten minutes. Changing these choices disarms the session. No raw media is saved by the API; providers process submitted evidence under your account settings. Encrypted incident metadata expires after 24 hours.").font(.caption)
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
struct ReplayView: View {
    @ObservedObject var model: GuardianModel
    @ObservedObject var library: ReplayLibrary
    @State private var importing = false
    var body: some View {
        NavigationStack { Form {
            Section("Wearer-POV media") {
                Text(library.status).font(.callout)
                Picker("Replay",selection: $library.selectedID) { Text("Select clip").tag(Optional<String>.none); ForEach(library.clips) { Text($0.title).tag(Optional($0.id)) } }
                if let clip = library.selected { Text("Reference label: \(clip.expected ?? "unlabeled"). This label and filename are never sent to Nemotron.").font(.caption); if let attribution = clip.attribution { Text(attribution).font(.caption) } }
                Button("Fetch replay index from backend") { Task { do { try await library.sync(api: model.makeAPI()) } catch { model.error = error.localizedDescription } } }
                Button("Download selected media") { Task { do { try await library.downloadSelected(api: model.makeAPI()) } catch { model.error = error.localizedDescription } } }
                Button("Import HEVC video / mono 16 kHz WAV") { importing = true }
                Button("Clear downloaded replay cache",role: .destructive) { do { try library.clearCache() } catch { model.error = error.localizedDescription } }
            }.disabled(model.armed)
            #if DEBUG
            Section("Actual MockDeviceKit events · arm first") {
                Button("Inject ‘Guardian help me’") { model.glasses.injectSpeech("Guardian help me") }
                Button("Replay free-fall and impact samples") { model.replayMotion() }
                Button("Inject ‘Guardian cancel’") { model.glasses.injectSpeech("Guardian cancel") }
                Button("Inject ‘Guardian SOS’") { model.glasses.injectSpeech("Guardian SOS") }
                Text("Events pass through SDK listeners and the same local detectors as real streams. Replay WAV is paced through the PCM pipeline because MockDeviceKit has no public PCM injection API.").font(.caption)
            }.disabled(!model.armed)
            Section("Failure rehearsal") {
                Button("Disconnect mock glasses") { model.glasses.mockFault("disconnect") }
                Button("Remove mock glasses") { model.glasses.mockFault("doff") }
                Button("Simulate thermal limit") { model.glasses.mockFault("thermal") }
                Button("Revoke mock camera permission") { model.glasses.mockFault("permission") }
            }.disabled(!model.armed)
            #endif
        }.navigationTitle("Replay lab").fileImporter(isPresented: $importing,allowedContentTypes: [.movie,.wav],allowsMultipleSelection: true) { result in do { try library.importFiles(result.get()) } catch { model.error = error.localizedDescription } } }
    }
}
struct HistoryView: View {
    @ObservedObject var model: GuardianModel
    var body: some View { NavigationStack { List { ForEach(model.history) { incident in VStack(alignment: .leading,spacing: 6) { Text(incident.detection?.summary ?? "Wearer SOS"); Text("\(incident.state.replacingOccurrences(of: "_",with: " ")) · \(Date(timeIntervalSince1970: incident.createdAt/1000).formatted())").font(.caption).foregroundStyle(.secondary) }.swipeActions { Button("Delete",role: .destructive) { Task { await model.deleteIncident(incident) } } } } }.overlay { if model.history.isEmpty { ContentUnavailableView("No retained incidents",systemImage: "clock",description: Text("Only encrypted metadata is retained for up to 24 hours.")) } }.navigationTitle("Incidents").refreshable { await model.loadHistory() }.task { await model.loadHistory() } } }
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
