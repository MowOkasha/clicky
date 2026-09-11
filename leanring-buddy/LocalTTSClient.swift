//
//  LocalTTSClient.swift
//  leanring-buddy
//
//  Uses AVSpeechSynthesizer to provide local text-to-speech.
//  Replaces the cloud-based ElevenLabs TTS client.
//

import AVFoundation
import Foundation

@MainActor
final class LocalTTSClient: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var _isPlaying = false
    private let preferredVoice: AVSpeechSynthesisVoice?

    override init() {
        // Try to find a good English voice (e.g., Samantha)
        let voices = AVSpeechSynthesisVoice.speechVoices()
        if let samantha = voices.first(where: { $0.identifier.contains("Samantha") }) {
            self.preferredVoice = samantha
        } else if let englishVoice = voices.first(where: { $0.language.starts(with: "en-") }) {
            self.preferredVoice = englishVoice
        } else {
            self.preferredVoice = AVSpeechSynthesisVoice(language: "en-US")
        }
        
        super.init()
        self.synthesizer.delegate = self
    }

    /// Sends `text` to AVSpeechSynthesizer to speak.
    /// This method signature is `async throws` to match the previous ElevenLabsTTSClient.
    func speakText(_ text: String) async throws {
        stopPlayback()

        let utterance = AVSpeechUtterance(string: text)
        if let voice = preferredVoice {
            utterance.voice = voice
        }
        
        // Slightly faster and more expressive
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.1
        utterance.pitchMultiplier = 1.1
        
        print("🔊 Local TTS: speaking \(text.count) characters")
        synthesizer.speak(utterance)
    }

    /// Whether TTS audio is currently playing back.
    var isPlaying: Bool {
        _isPlaying || synthesizer.isSpeaking
    }

    /// Stops any in-progress playback immediately.
    func stopPlayback() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        _isPlaying = false
    }
    
    // MARK: - AVSpeechSynthesizerDelegate
    
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self._isPlaying = true
        }
    }
    
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self._isPlaying = false
        }
    }
    
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self._isPlaying = false
        }
    }
}
