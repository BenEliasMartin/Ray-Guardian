import SwiftUI
import MWDATCore
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
            model.settings.mockUsesReplay = true
            model.settings.automaticSceneChecks = false
            model.settings.audio = .replay
            model.settings.keywords = .glasses
            model.settings.apiURL = ProcessInfo.processInfo.environment["GUARDIAN_UI_TEST_API"] ?? "http://127.0.0.1:8787"
            model.settings.clientToken = "ui-test-only-client-token-never-production-12345"
            model.settings.consent.capture = true; model.settings.consent.cloud = true; model.settings.consent.audio = true
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
        }.onChange(of: scenePhase) { _,phase in
            if phase != .inactive || !model.starting { model.sceneChanged(active: phase == .active) }
        }
    } }
}
