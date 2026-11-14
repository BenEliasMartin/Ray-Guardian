import Combine
import AVFoundation
import Speech
import GuardianCore

/// Converts both DAT and phone buffers into the identical mono 16 kHz processing format.
enum PCMConverter {
    static func samples(_ input: AVAudioPCMBuffer) -> [Int16] {
        guard input.frameLength > 0, let format = AVAudioFormat(commonFormat: .pcmFormatInt16,sampleRate: 16000,channels: 1,interleaved: false), let converter = AVAudioConverter(from: input.format,to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format,frameCapacity: AVAudioFrameCount(Double(input.frameLength)*16000/input.format.sampleRate)+32) else { return [] }
        var supplied = false, error: NSError?
        let status = converter.convert(to: output,error: &error) { _,state in if supplied { state.pointee = .noDataNow; return nil }; supplied = true; state.pointee = .haveData; return input }
        guard error == nil, status != .error, let channel = output.int16ChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel,count: Int(output.frameLength)))
    }
}
@MainActor final class PhoneAudio: ObservableObject {
    @Published var status = "Off"
    var onPCM: (([Int16]) -> Void)?, onTranscript: ((String,Bool,Float) -> Void)?, onFailure: ((String) -> Void)?
    private var engine: AVAudioEngine?, recognizer: SFSpeechRecognizer?, request: SFSpeechAudioBufferRecognitionRequest?, recognition: SFSpeechRecognitionTask?
    private var restart: Task<Void,Never>?, epoch = UUID(), wantsASR = false, suppressed = false
    private var recognitionID = UUID()
    func start(localASR: Bool) async throws {
        stop(); let token = epoch
        guard await AVAudioApplication.requestRecordPermission() else { throw DeviceError.message("Phone microphone permission denied.") }
        if localASR {
            let authorization = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) } }
            guard authorization == .authorized, let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.supportsOnDeviceRecognition else { throw DeviceError.message("On-device English speech recognition is unavailable. Download the language or use glasses speech; cloud ASR is not used for standby.") }
            self.recognizer = recognizer
        }
        guard token == epoch else { throw CancellationError() }; wantsASR = localASR
        let audioSession = AVAudioSession.sharedInstance(); try audioSession.setCategory(.playAndRecord,mode: .voiceChat,options: [.defaultToSpeaker,.allowBluetooth]); try audioSession.setActive(true)
        guard let microphone = audioSession.availableInputs?.first(where: { $0.portType == .builtInMic }) else { throw DeviceError.message("The selected phone microphone is unavailable.") }; try audioSession.setPreferredInput(microphone)
        let engine = AVAudioEngine(); self.engine = engine
        if localASR { beginRecognition(token: token) }
        engine.inputNode.installTap(onBus: 0,bufferSize: 1024,format: nil) { [weak self] buffer,_ in
            let pcm = PCMConverter.samples(buffer)
            guard let copy = AVAudioPCMBuffer(pcmFormat:buffer.format,frameCapacity:buffer.frameLength) else { return }
            copy.frameLength = buffer.frameLength
            let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating:buffer.audioBufferList)), destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for index in 0..<min(source.count,destination.count) { if let src = source[index].mData,let dst = destination[index].mData { memcpy(dst,src,Int(source[index].mDataByteSize)) } }
            Task { @MainActor in guard let self, self.epoch == token,!self.suppressed else { return }; self.request?.append(copy); self.onPCM?(pcm) }
        }
        engine.prepare(); try engine.start(); status = localASR ? "Phone local speech + microphone active" : "Phone microphone active during capture"
    }
    private func beginRecognition(token: UUID) {
        guard !suppressed else { return }; let id = UUID(); recognitionID = id
        recognition?.cancel(); request?.endAudio()
        let request = SFSpeechAudioBufferRecognitionRequest(); request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true; request.taskHint = .confirmation; self.request = request
        recognition = recognizer?.recognitionTask(with: request) { [weak self] result,error in Task { @MainActor in
            guard let self, self.epoch == token,self.recognitionID == id,!self.suppressed else { return }
            if let result { let confidence = result.bestTranscription.segments.last?.confidence ?? -1; self.onTranscript?(result.bestTranscription.formattedString,result.isFinal,confidence) }
            if error != nil || result?.isFinal == true { self.scheduleRestart(token: token) }
        } }
        scheduleRestart(token: token, seconds: 50)
    }
    private func scheduleRestart(token: UUID, seconds: Double = 0.25) {
        restart?.cancel(); restart = Task { [weak self] in try? await Task.sleep(for: .seconds(seconds)); guard !Task.isCancelled, let self, self.epoch == token, self.wantsASR,!self.suppressed else { return }; self.beginRecognition(token: token) }
    }
    func setSuppressed(_ value: Bool) {
        suppressed = value
        if value { recognitionID = UUID(); restart?.cancel(); recognition?.cancel(); request?.endAudio(); request = nil }
        else if wantsASR,engine != nil { beginRecognition(token:epoch) }
    }
    func stop() { epoch = UUID(); restart?.cancel(); restart = nil; recognition?.cancel(); recognition = nil; request?.endAudio(); request = nil; if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop() }; engine = nil; recognizer = nil; wantsASR = false; status = "Off" }
}
@MainActor final class VoicePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var playing = false
    private var suppressedUntil = 0.0
    var suppressInput: Bool { playing || ProcessInfo.processInfo.systemUptime < suppressedUntil }
    private var player: AVAudioPlayer?
    func play(_ data: Data) throws {
        stop(); let session = AVAudioSession.sharedInstance(); try session.setCategory(.playAndRecord,mode: .voiceChat,options: [.defaultToSpeaker,.allowBluetooth]); try session.setActive(true)
        let player = try AVAudioPlayer(data: data); self.player = player; player.delegate = self; player.prepareToPlay()
        guard player.play() else { throw DeviceError.message("Voice playback failed.") }; playing = true; suppressedUntil = .infinity
    }
    func stop() { player?.stop(); player = nil; playing = false; suppressedUntil = ProcessInfo.processInfo.systemUptime+2 }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer,successfully flag: Bool) { Task { @MainActor in self.playing = false; self.player = nil; self.suppressedUntil = ProcessInfo.processInfo.systemUptime+2 } }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer,error: Error?) { Task { @MainActor in self.playing = false; self.player = nil; self.suppressedUntil = ProcessInfo.processInfo.systemUptime+2 } }
}
