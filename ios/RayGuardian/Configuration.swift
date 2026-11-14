import Combine
import Foundation
import Security
import GuardianCore

enum InputMode: String, CaseIterable, Identifiable { case mock = "Mock glasses", real = "Real glasses"; var id: String { rawValue } }
enum KeywordMode: String, CaseIterable, Identifiable { case glasses = "Glasses local speech", phone = "Phone local speech", off = "Manual and motion only"; var id: String { rawValue } }
enum AudioMode: String, CaseIterable, Identifiable { case replay = "Replay WAV", glasses = "Glasses stream (experimental)", phone = "Phone microphone"; var id: String { rawValue } }
enum Keychain {
    static let service = "com.rayguardian.companion"
    static func read(_ account: String) -> String? {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var result: CFTypeRef?; guard SecItemCopyMatching(query as CFDictionary,&result) == errSecSuccess,let data = result as? Data else { return nil }; return String(data: data,encoding: .utf8)
    }
    static func write(_ value: String, account: String) throws {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var attributes = query; attributes[kSecValueData as String] = Data(value.utf8); attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(attributes as CFDictionary,nil) == errSecSuccess else { throw DeviceError.message("Cannot save client configuration to Keychain.") }
    }
}
@MainActor final class Settings: ObservableObject {
    #if DEBUG
    var usesEphemeralUITestConfiguration = false
    @Published var mockUsesReplay = false
    #endif
    @Published var apiURL: String
    @Published var clientToken: String
    @Published var input: InputMode = .mock { didSet { if input == .real && audio == .replay { audio = .glasses } } }
    @Published var keywords: KeywordMode = .phone
    @Published var audio: AudioMode = .phone
    @Published var consent = Consent()
    @Published var automaticSceneChecks = false
    @Published var phoneMotionTesting = false
    @Published var elevenLabsListening = false
    @Published var heartRateEnabled = false
    @Published var heartRateThreshold = 160
    init() {
        apiURL = Keychain.read("apiURL") ?? (Bundle.main.object(forInfoDictionaryKey: "GuardianAPIURL") as? String ?? "http://127.0.0.1:8787")
        clientToken = Keychain.read("clientToken") ?? (Bundle.main.object(forInfoDictionaryKey: "GuardianClientToken") as? String ?? "")
        #if !DEBUG
        input = .real; audio = .glasses; keywords = .glasses
        #endif
    }
    func save() throws {
        _ = try GuardianAPI(url:apiURL,token:clientToken)
        #if DEBUG
        if usesEphemeralUITestConfiguration { return }
        #endif
        try Keychain.write(apiURL,account:"apiURL"); try Keychain.write(clientToken,account:"clientToken")
    }
}
