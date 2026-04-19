import Foundation
import AVFoundation

/// Plays TTS and remote audio on the Mac's default output. Driven by
/// `homebar_speak` events received over the HA WebSocket.
@MainActor
final class MediaPlayerService {
    static let shared = MediaPlayerService()

    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVPlayer?

    func speak(_ text: String, rate: Float? = nil, volume: Float = 1.0, voiceID: String? = nil) {
        guard !text.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        if let rate { utterance.rate = max(0, min(1, rate)) }
        utterance.volume = max(0, min(1, volume))
        if let voiceID, let voice = AVSpeechSynthesisVoice(identifier: voiceID) {
            utterance.voice = voice
        }
        synthesizer.speak(utterance)
    }

    func play(_ url: URL, volume: Float = 1.0) {
        player?.pause()
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.volume = max(0, min(1, volume))
        p.play()
        self.player = p
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        player?.pause()
        player = nil
    }
}
