import Foundation
import AVFoundation

/// 拍点提示音：预生成两段短促的正弦衰减，丢给 AVAudioPlayerNode 播。
/// 比调系统音可控 —— 能分强拍/弱拍，也不受静音键影响。
final class ClickPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var strongBuf: AVAudioPCMBuffer?
    private var weakBuf: AVAudioPCMBuffer?
    private var started = false

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)
            ?? AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        strongBuf = ClickPlayer.makeBuffer(format: format, freq: 1500, dur: 0.085, gain: 0.30)
        weakBuf = ClickPlayer.makeBuffer(format: format, freq: 950, dur: 0.045, gain: 0.22)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    func start() {
        if started {
            if !node.isPlaying { node.play() }
            return
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            node.play()
            started = true
        } catch {
            // 出不了声不影响其它功能，静默失败
        }
    }

    func click(strong: Bool) {
        guard started, node.isPlaying else { return }
        guard let buf = strong ? strongBuf : weakBuf else { return }
        node.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
    }

    private static func makeBuffer(format: AVAudioFormat, freq: Double, dur: Double, gain: Float) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(format.sampleRate * dur)
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let ch = buf.floatChannelData?[0] else { return nil }
        buf.frameLength = frames
        for i in 0..<Int(frames) {
            let t = Double(i) / format.sampleRate
            let env = exp(-t * 30)
            ch[i] = Float(sin(2 * .pi * freq * t) * env) * gain
        }
        return buf
    }
}
