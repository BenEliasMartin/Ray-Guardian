import SwiftUI
import MWDATCore
@main @MainActor struct RayGuardianApp: App {
    @StateObject private var model: GuardianModel
    @Environment(\.scenePhase) private var scenePhase
    init() {
        var setupError: String?
        do { try Wearables.configure() } catch { setupError = error.localizedDescription }
        let model = GuardianModel(); model.error = setupError; _model = StateObject(wrappedValue: model)
    }
    var body: some Scene { WindowGroup {
        ContentView(model: model).onOpenURL { url in
            guard URLComponents(url: url,resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true else { return }
            Task { do { _ = try await Wearables.shared.handleUrl(url) } catch { model.error = error.localizedDescription } }
        }.onChange(of: scenePhase) { _,phase in model.sceneChanged(active: phase == .active) }
    } }
}
