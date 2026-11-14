import SwiftUI
import MWDATCore
import GuardianCore
@main @MainActor struct RayGuardianApp: App {
    @StateObject private var model: GuardianModel
    @Environment(\.scenePhase) private var scenePhase
    init() {
        var setupError: String?
        do { try Wearables.configure() } catch WearablesError.alreadyConfigured { } catch { setupError = "Wearables configuration: \(error.localizedDescription). Check Meta and Apple settings in Local.xcconfig." }
        let model = GuardianModel(); model.error = setupError; model.glasses.configurationError = setupError
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--guardian-ui-fixture") {
            model.settings.usesEphemeralUITestConfiguration = true
            model.settings.input = .mock
            model.settings.mockUsesReplay = true
            model.settings.automaticSceneChecks = false
            model.settings.preTriggerFrames = false
            model.settings.handGestures = false
            model.settings.recordClipAudio = true
            model.settings.phoneMotionTesting = false
            model.settings.elevenLabsListening = false
            model.settings.speakWithoutDisplay = false
            model.settings.heartRateEnabled = false
            model.settings.audio = .replay
            model.settings.keywords = .glasses
            model.settings.apiURL = ProcessInfo.processInfo.environment["GUARDIAN_UI_TEST_API"] ?? "http://127.0.0.1:8787"
            model.settings.clientToken = "ui-test-only-client-token-never-production-12345"
            var consent = Consent()
            consent.capture = true
            consent.cloud = true
            consent.audio = true
            model.settings.consent = consent
            model.debugStopAfterFirstFrame = ProcessInfo.processInfo.arguments.contains("--guardian-stop-after-first-frame")
            model.statusForUITesting()
        }
        #endif
        _model = StateObject(wrappedValue: model)
    }
    var body: some Scene { WindowGroup {
        ContentView(model: model).onOpenURL { url in
            guard URLComponents(url: url,resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true else { return }
            Task { do { if let error = model.glasses.configurationError { throw DeviceError.message(error) }; _ = try await Wearables.shared.handleUrl(url) } catch { model.error = error.localizedDescription } }
        }.task(id: scenePhase) {
            #if DEBUG
            if scenePhase == .active,
               ProcessInfo.processInfo.arguments.contains("--guardian-check-glasses"),
               model.glasses.permissionStatus.isEmpty {
                await model.checkGlassesConnection()
                print("Ray Guardian glasses check: \(model.glasses.permissionStatus)")
            }
            #endif
        }.onChange(of: scenePhase) { _,phase in
            if phase != .inactive || !model.starting { model.sceneChanged(active: phase == .active) }
        }
    } }
}
