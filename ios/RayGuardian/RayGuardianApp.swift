import MWDATCore
import SwiftUI

@main
struct RayGuardianApp: App {
    private let monitor: LiveMonitor

    @MainActor init() {
        do {
            try Wearables.configure()
            monitor = LiveMonitor()
        } catch {
            monitor = LiveMonitor(setupError: error.localizedDescription)
        }
    }

    var body: some Scene {
        WindowGroup { MonitorView(monitor: monitor) }
    }
}

private struct MonitorView: View {
    @Environment(\.scenePhase) private var phase
    @Bindable var monitor: LiveMonitor

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Live sensor input · Simulated dispatch").font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(monitor.status)
                    if let preview = monitor.preview {
                        Image(uiImage: preview).resizable().scaledToFit().frame(maxHeight: 280)
                            .frame(maxWidth: .infinity).accessibilityLabel("Latest glasses camera image")
                    }
                    if !monitor.registered {
                        Button("Connect Meta glasses") { monitor.register() }
                            .buttonStyle(.borderedProminent).disabled(!monitor.configured)
                    }
                    if monitor.running || monitor.preparing {
                        Button("Stop live monitoring") { monitor.stop() }.buttonStyle(.borderedProminent)
                    } else {
                        Toggle("Detect sustained loud sound from glasses microphone", isOn: $monitor.useAudio)
                        Toggle("Send sampled camera frames to Verda / Nemotron", isOn: $monitor.useVision)
                            .disabled(!monitor.backendConfigured)
                        Button("Start live monitoring") { monitor.start() }
                            .buttonStyle(.borderedProminent).disabled(!monitor.registered)
                    }

                    Text(monitor.audioStatus).font(.subheadline)
                    Text(monitor.analysis).font(.subheadline)
                    if let incident = monitor.incident { Text(incident).font(.headline) }
                    if monitor.remaining != nil {
                        Button("I'm OK · Cancel check-in") { monitor.cancelCheckIn() }.buttonStyle(.borderedProminent)
                    }
                    Button("Simulate SOS now") { monitor.manualSOS() }
                        .buttonStyle(.bordered).disabled(monitor.dispatchInProgress || !monitor.backendConfigured)
                    if let receipt = monitor.receipt { Text(receipt).font(.subheadline) }
                    if monitor.canRetry {
                        Button("Retry simulated dispatch") { monitor.retryDispatch() }.buttonStyle(.bordered)
                    }
                }.padding()
            }.navigationTitle("Ray Guardian")
        }
        .task { await monitor.observeRegistration() }
        .onOpenURL { monitor.handle(url: $0) }
        .onChange(of: phase, initial: true) { _, next in monitor.setForeground(next == .active) }
    }
}
