import Combine
import AVFoundation
import Speech
import GuardianCore

/// Keep an explicitly selected phone microphone while allowing glasses output.
/// DAT connection and the iPhone's Bluetooth audio route are separate connections.
@MainActor enum GuardianAudioRoute {
    static func configure(phoneMicrophone: Bool, requireBluetooth: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        if phoneMicrophone {
            var options: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP]
            if !requireBluetooth { options.insert(.defaultToSpeaker) }
            try session.setCategory(.playAndRecord,mode:.default,options:options)
        } else {
            // Output-only cues must not take over the Bluetooth microphone from
            // DAT speech or open a phone microphone while manual-only is armed.
            try session.setCategory(.playback,mode:.spokenAudio)
        }
        try session.setActive(true)
        if phoneMicrophone {
            guard let microphone = session.availableInputs?.first(where: { $0.portType == .builtInMic }) else {
                throw DeviceError.message("The selected phone microphone is unavailable.")
            }
            try session.setPreferredInput(microphone)
        }
        if requireBluetooth {
            if phoneMicrophone { try session.overrideOutputAudioPort(.none) }
            guard session.currentRoute.outputs.contains(where: { [.bluetoothA2DP,.bluetoothHFP,.bluetoothLE].contains($0.portType) }) else {
                throw DeviceError.message("Select your Meta glasses as the iPhone audio output, then run Test glasses audio in Setup. DAT pairing alone does not select audio output.")
            }
        }
    }
    static var description: String {
        AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName).joined(separator:", ")
    }
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
    var onPCM: (([Int16],Double) -> Void)?, onTranscript: ((String,Bool,Float) -> Void)?, onFailure: ((String) -> Void)?
    private var engine: AVAudioEngine?, recognizer: SFSpeechRecognizer?, request: SFSpeechAudioBufferRecognitionRequest?, recognition: SFSpeechRecognitionTask?
    private var restart: Task<Void,Never>?, epoch = UUID(), wantsASR = false, suppressed = false
    private var recognitionID = UUID(), recognitionFailures = 0
    private var endUtterance: Task<Void,Never>?
    var captureEnabled = false
    var requiresBluetoothOutput = false
    func requestPermissions(localSpeech: Bool) async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw DeviceError.message("Phone microphone permission denied.") }
        if localSpeech {
            let authorization = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning:$0) } }
            guard authorization == .authorized else { throw DeviceError.message("Local speech permission denied.") }
        }
    }
    func start(localASR: Bool) async throws {
        stop(); recognitionFailures = 0; let token = epoch
        guard await AVAudioApplication.requestRecordPermission() else { throw DeviceError.message("Phone microphone permission denied.") }
        if localASR {
            let authorization = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) } }
            guard authorization == .authorized, let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.supportsOnDeviceRecognition,recognizer.isAvailable else { throw DeviceError.message("On-device English speech recognition is unavailable. Download the language or use glasses speech; cloud ASR is not used for standby.") }
            self.recognizer = recognizer
        }
        guard token == epoch else { throw CancellationError() }; wantsASR = localASR
        try GuardianAudioRoute.configure(phoneMicrophone:true,requireBluetooth:requiresBluetoothOutput)
        let engine = AVAudioEngine(); self.engine = engine
        if localASR { beginRecognition(token: token) }
        engine.inputNode.installTap(onBus: 0,bufferSize: 1024,format: nil) { [weak self] buffer,_ in
            let arrivedAt = ProcessInfo.processInfo.systemUptime
            guard let copy = AVAudioPCMBuffer(pcmFormat:buffer.format,frameCapacity:buffer.frameLength) else { return }
            copy.frameLength = buffer.frameLength
            let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating:buffer.audioBufferList)), destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for index in 0..<min(source.count,destination.count) { if let src = source[index].mData,let dst = destination[index].mData { memcpy(dst,src,Int(source[index].mDataByteSize)) } }
            Task { @MainActor in
                guard let self,self.epoch == token,!self.suppressed else { return }
                self.request?.append(copy)
                // Standby feeds local ASR only. Convert/export PCM only for a
                // permitted event window; no standby PCM ring buffer is retained.
                if self.captureEnabled { self.onPCM?(PCMConverter.samples(copy),arrivedAt) }
            }
        }
        engine.prepare(); try engine.start(); status = localASR ? "Phone local speech + microphone active" : "Phone microphone active · local speech off"
    }
    private func beginRecognition(token: UUID) {
        guard !suppressed else { return }; let id = UUID(); recognitionID = id
        endUtterance?.cancel(); recognition?.cancel(); request?.endAudio()
        let request = SFSpeechAudioBufferRecognitionRequest(); request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true; request.taskHint = .dictation; self.request = request
        recognition = recognizer?.recognitionTask(with: request) { [weak self] result,error in Task { @MainActor in
            guard let self, self.epoch == token,self.recognitionID == id,!self.suppressed else { return }
            if let result { let confidence = result.bestTranscription.segments.last?.confidence ?? -1; self.onTranscript?(result.bestTranscription.formattedString,result.isFinal,confidence) }
            // Finalize settled speech promptly, including final-only cancel/SOS
            // commands, instead of waiting for the 50-second session rotation.
            self.endUtterance?.cancel()
            if let result,!result.isFinal {
                self.endUtterance = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1.2))
                    guard !Task.isCancelled,let self,self.epoch == token,self.recognitionID == id,!self.suppressed else { return }
                    let ending = self.request; self.request = nil; ending?.endAudio()
                    self.scheduleRestart(token:token,seconds:2)
                }
            }
            if let error {
                self.recognitionFailures += 1; self.status = "Local speech unavailable: \(error.localizedDescription)"
                if self.recognitionFailures >= 3 { self.onFailure?(self.status); return }
                self.scheduleRestart(token:token,seconds:2)
            } else if result?.isFinal == true { self.recognitionFailures = 0; self.scheduleRestart(token:token) }
        } }
        scheduleRestart(token: token, seconds: 50)
    }
    private func scheduleRestart(token: UUID, seconds: Double = 0.25) {
        restart?.cancel(); restart = Task { [weak self] in try? await Task.sleep(for: .seconds(seconds)); guard !Task.isCancelled, let self, self.epoch == token, self.wantsASR,!self.suppressed else { return }; self.beginRecognition(token: token) }
    }
    func setSuppressed(_ value: Bool) {
        suppressed = value
        if value { recognitionID = UUID(); endUtterance?.cancel(); restart?.cancel(); recognition?.cancel(); request?.endAudio(); request = nil }
        else if wantsASR,engine != nil { beginRecognition(token:epoch) }
    }
    func stop() { epoch = UUID(); captureEnabled = false; endUtterance?.cancel(); endUtterance = nil; restart?.cancel(); restart = nil; recognition?.cancel(); recognition = nil; request?.endAudio(); request = nil; if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop() }; engine = nil; recognizer = nil; wantsASR = false; status = "Off" }
}
@MainActor final class VoicePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    @Published private(set) var playing = false
    @Published private(set) var inputSuppressed = false
    @Published private(set) var status = "Voice idle"
    var suppressInput: Bool { inputSuppressed }
    var requiresBluetoothOutput = false
    var usesPhoneMicrophone = false
    private var player: AVAudioPlayer?
    private lazy var synthesizer: AVSpeechSynthesizer = { let value = AVSpeechSynthesizer(); value.delegate = self; return value }()
    private var utterance: AVSpeechUtterance?
    private var resumeTask: Task<Void,Never>?
    func prepareRoute() throws {
        try GuardianAudioRoute.configure(phoneMicrophone:usesPhoneMicrophone,requireBluetooth:requiresBluetoothOutput)
        status = "Audio output: \(GuardianAudioRoute.description)"
    }
    func play(_ data: Data) throws {
        stop(); try prepareRoute()
        let player = try AVAudioPlayer(data: data); self.player = player; player.delegate = self; player.prepareToPlay()
        beginOutput()
        guard player.play() else { stop(); throw DeviceError.message("Voice playback failed.") }
    }
    /// A check-in must be audible even when cloud synthesis is slow or unavailable.
    func speakLocally(_ text: String) throws {
        stop(); try prepareRoute()
        let utterance = AVSpeechUtterance(string:text)
        utterance.voice = AVSpeechSynthesisVoice(language:"en-US")
        self.utterance = utterance
        beginOutput(); synthesizer.speak(utterance)
    }
    private func beginOutput() { resumeTask?.cancel(); inputSuppressed = true; playing = true }
    private func finishedOutput() {
        playing = false
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for:.milliseconds(350))
            guard !Task.isCancelled,let self,!self.playing else { return }
            self.inputSuppressed = false
        }
    }
    func stop() {
        resumeTask?.cancel(); player?.stop(); player = nil; utterance = nil
        synthesizer.stopSpeaking(at:.immediate)
        finishedOutput()
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer,successfully flag: Bool) {
        Task { @MainActor in guard self.player === player else { return }; self.player = nil; self.finishedOutput() }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer,error: Error?) {
        Task { @MainActor in guard self.player === player else { return }; self.player = nil; self.status = "Voice playback failed"; self.finishedOutput() }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in guard self.utterance === utterance else { return }; self.utterance = nil; self.finishedOutput() }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in guard self.utterance === utterance else { return }; self.utterance = nil; self.finishedOutput() }
    }
}
