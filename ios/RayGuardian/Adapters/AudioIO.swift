import Combine
import AVFoundation
import Speech
import GuardianCore

@MainActor private func activateGuardianAudio(phoneMicrophone: Bool) throws {
    let session = AVAudioSession.sharedInstance()
    let category: AVAudioSession.Category = phoneMicrophone ? .playAndRecord : .playback
    let mode: AVAudioSession.Mode = phoneMicrophone ? .default : .spokenAudio
    let options: AVAudioSession.CategoryOptions = phoneMicrophone ? [.defaultToSpeaker, .allowBluetoothA2DP] : []
    if session.category != category || session.mode != mode || session.categoryOptions != options {
        try session.setCategory(category, mode: mode, options: options)
    }
    try session.setActive(true)
}

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
    var captureEnabled = false
    var onPCM: (([Int16],Double) -> Void)?, onTranscript: ((String,Bool,Float) -> Void)?, onFailure: ((String) -> Void)?
    private var engine: AVAudioEngine?, recognizer: SFSpeechRecognizer?, request: SFSpeechAudioBufferRecognitionRequest?, recognition: SFSpeechRecognitionTask?
    private var restart: Task<Void,Never>?, epoch = UUID(), wantsASR = false, suppressed = false
    private var keepsCommandListenerDuringPlayback = false
    private var requiresLocalASR = false
    private var recognitionID = UUID(), recognitionFailures = 0
    func requestPermissions(localSpeech: Bool) async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw DeviceError.message("Phone microphone permission denied.") }
        if localSpeech {
            let authorization = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning:$0) } }
            guard authorization == .authorized else { throw DeviceError.message("Local speech permission denied.") }
        }
    }
    func start(localASR: Bool, listenForCancel: Bool = false) async throws {
        stop(); recognitionFailures = 0; let token = epoch
        guard await AVAudioApplication.requestRecordPermission() else { throw DeviceError.message("Phone microphone permission denied.") }
        if localASR || listenForCancel {
            let authorization = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) } }
            guard token == epoch else { throw CancellationError() }
            if authorization == .authorized, let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
               recognizer.supportsOnDeviceRecognition, recognizer.isAvailable {
                self.recognizer = recognizer
            } else if localASR {
                throw DeviceError.message("On-device English speech recognition is unavailable. Download the language or use glasses speech.")
            }
        }
        guard token == epoch else { throw CancellationError() }
        wantsASR = recognizer != nil
        requiresLocalASR = localASR
        keepsCommandListenerDuringPlayback = listenForCancel
        let audioSession = AVAudioSession.sharedInstance(); try activateGuardianAudio(phoneMicrophone: true)
        guard let microphone = audioSession.availableInputs?.first(where: { $0.portType == .builtInMic }) else { throw DeviceError.message("The selected phone microphone is unavailable.") }; try audioSession.setPreferredInput(microphone)
        let engine = AVAudioEngine(); self.engine = engine
        if wantsASR { beginRecognition(token: token) }
        engine.inputNode.installTap(onBus: 0,bufferSize: 1024,format: nil) { [weak self] buffer,_ in
            let arrivedAt = ProcessInfo.processInfo.systemUptime
            guard let copy = AVAudioPCMBuffer(pcmFormat:buffer.format,frameCapacity:buffer.frameLength) else { return }
            copy.frameLength = buffer.frameLength
            let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating:buffer.audioBufferList)), destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for index in 0..<min(source.count,destination.count) { if let src = source[index].mData,let dst = destination[index].mData { memcpy(dst,src,Int(source[index].mDataByteSize)) } }
            Task { @MainActor in
                guard let self, self.epoch == token else { return }
                if !self.suppressed || self.keepsCommandListenerDuringPlayback { self.request?.append(copy) }
                if !self.suppressed, self.captureEnabled { self.onPCM?(PCMConverter.samples(copy),arrivedAt) }
            }
        }
        engine.prepare(); try engine.start()
        status = wantsASR ? "Phone microphone and local speech active"
            : (listenForCancel ? "Local voice cancel unavailable · use the cancel button" : "Phone microphone active")
    }
    private func beginRecognition(token: UUID) {
        guard !suppressed || keepsCommandListenerDuringPlayback else { return }; let id = UUID(); recognitionID = id
        recognition?.cancel(); request?.endAudio()
        let request = SFSpeechAudioBufferRecognitionRequest(); request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true; request.taskHint = .confirmation; self.request = request
        request.contextualStrings = ["Guardian cancel", "Guardian I am okay"]
        recognition = recognizer?.recognitionTask(with: request) { [weak self] result,error in Task { @MainActor in
            guard let self, self.epoch == token, self.recognitionID == id else { return }
            if let result { let confidence = result.bestTranscription.segments.last?.confidence ?? -1; self.onTranscript?(result.bestTranscription.formattedString,result.isFinal,confidence) }
            guard self.epoch == token, self.recognitionID == id else { return }
            if let error {
                self.recognitionFailures += 1; self.status = "Local speech unavailable: \(error.localizedDescription)"
                if self.recognitionFailures >= 3 {
                    if self.requiresLocalASR { self.onFailure?(self.status); return }
                    self.status = "Local voice cancel reconnecting · cancel button available"
                    self.scheduleRestart(token: token, seconds: 2)
                    return
                }
                self.scheduleRestart(token:token,seconds:2)
            } else if result != nil {
                self.recognitionFailures = 0
                if self.status != "Phone microphone and local speech active" {
                    self.status = "Phone microphone and local speech active"
                }
                if result?.isFinal == true { self.scheduleRestart(token: token) }
            }
        } }
        scheduleRestart(token: token, seconds: 50)
    }
    private func scheduleRestart(token: UUID, seconds: Double = 0.25) {
        restart?.cancel(); restart = Task { [weak self] in try? await Task.sleep(for: .seconds(seconds)); guard !Task.isCancelled, let self, self.epoch == token, self.wantsASR else { return }; self.beginRecognition(token: token) }
    }
    func setSuppressed(_ value: Bool) {
        guard value != suppressed else { return }
        suppressed = value
        if keepsCommandListenerDuringPlayback { return }
        if value { recognitionID = UUID(); restart?.cancel(); recognition?.cancel(); request?.endAudio(); request = nil }
        else if wantsASR,engine != nil { beginRecognition(token:epoch) }
    }
    func stop() { epoch = UUID(); restart?.cancel(); restart = nil; recognition?.cancel(); recognition = nil; request?.endAudio(); request = nil; if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop() }; engine = nil; recognizer = nil; wantsASR = false; status = "Off" }
}
@MainActor final class VoicePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    @Published private(set) var playing = false
    var usesPhoneMicrophone = false
    private var suppressedUntil = 0.0
    var suppressInput: Bool { playing || ProcessInfo.processInfo.systemUptime < suppressedUntil }
    private var player: AVAudioPlayer?
    private let synthesizer = AVSpeechSynthesizer()
    private var utterance: AVSpeechUtterance?

    func speakCheckIn() throws {
        try speak("Are you okay? You can cancel the check-in.")
    }

    func speak(_ text: String) throws {
        stop()
        try activateGuardianAudio(phoneMicrophone: usesPhoneMicrophone)
        synthesizer.delegate = self
        synthesizer.usesApplicationAudioSession = true
        let message = AVSpeechUtterance(string: text)
        message.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance = message
        playing = true
        suppressedUntil = .infinity
        synthesizer.speak(message)
    }

    func play(_ data: Data) throws {
        stop(); try activateGuardianAudio(phoneMicrophone: usesPhoneMicrophone)
        let player = try AVAudioPlayer(data: data); self.player = player; player.delegate = self; player.prepareToPlay()
        guard player.play() else { throw DeviceError.message("Voice playback failed.") }; playing = true; suppressedUntil = .infinity
    }
    static func alertToneSamples() -> [Int16] {
        let samples: [Int16] = (0..<9_600).map { index in
            let position = index % 4_800
            guard position < 2_720 else { return 0 }
            let fade = Double(min(160, position, 2_719 - position)) / 160
            return Int16(10_000 * fade * sin(2 * .pi * 880 * Double(position) / 16_000))
        }
        return samples
    }

    func playAlertTone() throws {
        try play(PCM16WAV.encode(Self.alertToneSamples()))
    }

    func renderSpeech(_ text: String) async -> [Int16] {
        let renderer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        let (stream, continuation) = AsyncStream<[Int16]>.makeStream()
        renderer.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 {
                continuation.finish()
            } else {
                continuation.yield(PCMConverter.samples(pcm))
            }
        }
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            continuation.finish()
        }
        defer {
            timeout.cancel()
            renderer.stopSpeaking(at: .immediate)
        }
        var samples: [Int16] = []
        for await chunk in stream {
            samples.append(contentsOf: chunk)
        }
        return samples
    }

    func stop() {
        player?.stop(); player = nil
        utterance = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        playbackEnded()
    }
    private func playbackEnded() {
        playing = false
        suppressedUntil = ProcessInfo.processInfo.systemUptime + 2
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer,successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in guard self.player.map(ObjectIdentifier.init) == id else { return }; self.player = nil; self.playbackEnded() }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer,error: Error?) {
        audioPlayerDidFinishPlaying(player, successfully: false)
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in guard self.utterance.map(ObjectIdentifier.init) == id else { return }; self.utterance = nil; self.playbackEnded() }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        speechSynthesizer(synthesizer, didFinish: utterance)
    }
}
