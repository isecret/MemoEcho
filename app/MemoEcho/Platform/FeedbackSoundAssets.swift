import AVFoundation
import Foundation

/// The approved UFO pair, exported offline so playback matches the auditioned WAVs.
enum FeedbackSoundAssets {
    enum LoadError: Error {
        case missingResource(String)
        case invalidFormat(String)
    }

    static func makeBuffer(for cue: FeedbackSoundCue, bundle: Bundle = .main) throws -> AVAudioPCMBuffer {
        let name = cue == .start ? "ufo-start" : "ufo-end"
        guard let url = bundle.url(forResource: name, withExtension: "wav") else {
            throw LoadError.missingResource(name)
        }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate == 44_100,
              file.processingFormat.channelCount == 2,
              file.length > 0, file.length <= 44_100 * 2,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else {
            throw LoadError.invalidFormat(name)
        }
        try file.read(into: buffer)
        guard buffer.frameLength == AVAudioFrameCount(file.length) else {
            throw LoadError.invalidFormat(name)
        }
        return buffer
    }
}
