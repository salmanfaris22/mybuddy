import AVFoundation
import Foundation
import MyBuddyCore
import Speech

/// Push-to-talk speech recognition with Apple's Speech framework. Records only while the
/// user holds the talk control; prefers on-device recognition when the locale supports it.
@MainActor
public final class SpeechInputService {
    public enum Event: Sendable, Equatable {
        case partial(String)
        case final(String)
        case failed(String)
    }

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    public private(set) var isListening = false
    public private(set) var usesOnDeviceRecognition = false

    public init() {}

    /// Requests microphone + speech permission (shows system prompts on first use).
    public static func requestAuthorization() async -> (microphone: Bool, speech: Bool) {
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        return (mic, speech)
    }

    public func start(locale: Locale = .current, onLevel: @escaping @Sendable (Double) -> Void = { _ in },
                      onEvent: @escaping @Sendable (Event) -> Void) throws {
        stop()
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw NSError(domain: "MyBuddyVoice", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech recognition isn’t available for \(locale.identifier)."])
        }
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        usesOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        if usesOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
            onLevel(Self.level(of: buffer))
        }
        engine.prepare()
        try engine.start()
        isListening = true
        task = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                let text = result.bestTranscription.formattedString
                onEvent(result.isFinal ? .final(text) : .partial(text))
            } else if let error {
                onEvent(.failed(error.localizedDescription))
            }
        }
    }

    /// RMS level of a buffer mapped to 0…1 for the orb/meter.
    nonisolated static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(n))
        return Double(min(1, rms * 12))
    }

    /// Ends capture; the recognizer then delivers its final result.
    public func finish() {
        guard isListening else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        isListening = false
    }

    /// Cancels immediately (no final result).
    public func stop() {
        if isListening {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        task?.cancel()
        task = nil
        request = nil
        isListening = false
    }
}

/// Spoken responses with AVSpeechSynthesizer (voice, rate and mute are user settings).
@MainActor
public final class SpeechOutputService: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    public var muted = false
    public var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    public var voiceIdentifier: String?
    private var onFinish: (() -> Void)?

    override public init() {
        super.init()
        synthesizer.delegate = self
    }

    public static var availableVoices: [(id: String, name: String, language: String)] {
        AVSpeechSynthesisVoice.speechVoices().map { ($0.identifier, $0.name, $0.language) }
    }

    public func speak(_ text: String, onFinish: (() -> Void)? = nil) {
        guard !muted, !text.isEmpty else {
            onFinish?()
            return
        }
        synthesizer.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: text)
        u.rate = rate
        if let id = voiceIdentifier, let v = AVSpeechSynthesisVoice(identifier: id) { u.voice = v }
        self.onFinish = onFinish
        synthesizer.speak(u)
    }

    public func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        onFinish = nil
    }

    public var isSpeaking: Bool { synthesizer.isSpeaking }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            let done = self.onFinish
            self.onFinish = nil
            done?()
        }
    }
}
