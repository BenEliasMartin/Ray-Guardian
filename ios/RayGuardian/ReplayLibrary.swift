import Combine
import Foundation
import GuardianCore
@MainActor final class ReplayLibrary: ObservableObject {
    @Published var clips: [ReplayClip] = []
    @Published var selectedID: String?
    @Published var status = "Loading replay index"
    private let directory: URL
    init() {
        directory = FileManager.default.urls(for: .cachesDirectory,in: .userDomainMask)[0].appendingPathComponent("ReplayMedia",isDirectory: true)
        try? FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true,attributes: [.protectionKey:FileProtectionType.complete])
        if let url = Bundle.main.url(forResource: "manifest",withExtension: "json",subdirectory: "ReplayMedia"), let data = try? Data(contentsOf: url), let manifest = try? JSONDecoder().decode(ReplayManifest.self,from: data) { clips = manifest.clips; selectedID = clips.first?.id }
        status = clips.isEmpty ? "Prepare or import wearer-POV replay media" : "Replay index loaded"
    }
    var selected: ReplayClip? { clips.first { $0.id == selectedID } }
    func url(_ filename: String?) -> URL? {
        guard let filename, URL(fileURLWithPath: filename).lastPathComponent == filename else { return nil }
        if let bundled = Bundle.main.url(forResource: filename,withExtension: nil,subdirectory: "ReplayMedia") { return bundled }
        let cached = directory.appendingPathComponent(filename); return FileManager.default.fileExists(atPath: cached.path) ? cached : nil
    }
    func sync(api: GuardianAPI) async throws {
        let manifest: ReplayManifest = try await api.get("v1/replays")
        guard !manifest.clips.isEmpty else { throw DeviceError.message("Run scripts/prepare_demo_media.py on the backend host, or import a HEVC MP4 and PCM WAV locally.") }
        clips = manifest.clips; selectedID = selectedID ?? clips.first?.id; status = "Replay index synchronized"
    }
    func downloadSelected(api: GuardianAPI) async throws {
        guard let clip = selected else { throw DeviceError.message("Select a replay first.") }
        status = "Downloading replay; media stays in the device cache"
        for (kind,filename) in [("video",Optional(clip.video)),("audio",clip.audio)] {
            guard let filename, url(filename) == nil else { continue }
            guard URL(fileURLWithPath: filename).lastPathComponent == filename else { throw DeviceError.message("Invalid replay filename.") }
            let data = try await api.replay(id: clip.id,kind: kind)
            if kind == "audio" { _ = try PCM16WAV.decode(data) }
            try data.write(to: directory.appendingPathComponent(filename),options: [.atomic,.completeFileProtection])
        }
        status = "Replay ready"
    }
    func importFiles(_ urls: [URL]) throws {
        var video: String?, audio: String?
        for source in urls {
            let scoped = source.startAccessingSecurityScopedResource(); defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let ext = source.pathExtension.lowercased(); guard ["mp4","mov","wav"].contains(ext) else { continue }
            let data = try Data(contentsOf: source); guard data.count <= 100*1024*1024 else { throw DeviceError.message("Replay file exceeds 100 MB.") }
            let name = "import-\(UUID().uuidString).\(ext)"
            if ext == "wav" { _ = try PCM16WAV.decode(data); audio = name } else { video = name }
            try data.write(to: directory.appendingPathComponent(name),options: [.atomic,.completeFileProtection])
        }
        if let video {
            let id = UUID().uuidString
            struct Imported: Encodable { let id:String,title:String,video:String,audio:String? }
            let clip = try JSONDecoder().decode(ReplayClip.self,from: JSONEncoder().encode(Imported(id:id,title:"Imported wearer-POV clip",video:video,audio:audio)))
            clips.append(clip); selectedID = id
        } else if let audio, let selected, let index = clips.firstIndex(where: {$0.id == selected.id}) {
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(selected)) as! [String:Any]; object["audio"] = audio
            clips[index] = try JSONDecoder().decode(ReplayClip.self,from: JSONSerialization.data(withJSONObject: object))
        }
        status = "Imported media; video must be HEVC compatible with MockDeviceKit"
    }
    func clearCache() throws { try FileManager.default.removeItem(at: directory); try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true,attributes: [.protectionKey:FileProtectionType.complete]); status = "Replay cache deleted" }
}
