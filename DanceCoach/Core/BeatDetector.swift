import Foundation
import CoreGraphics
import Accelerate

struct BeatResult {
    var beats: [Double]
    var bpm: Double
    var downbeat: Int
    var strength: Double
}

/// 节拍检测。和网页版是同一套算法，只是把自写的 FFT 换成 Accelerate/vDSP。
///
/// 三级优先级：离线音频（谱通量）→ 实时音量包络 → 骨架运动能量。
/// 最后那级很关键：静音视频、或者拿不到音频解码时，舞蹈动作本身就踩在音乐上，
/// 用骨架的运动量照样能反推出节拍。
enum BeatDetector {

    // MARK: - 谱通量起始点包络

    static func onsetEnvelope(_ data: [Float], sampleRate: Double) -> (env: [Float], frameRate: Double)? {
        let n = 1024, hop = 256
        guard data.count > n, let fft = FFT(size: n) else { return nil }
        let frameCount = (data.count - n) / hop + 1
        var env = [Float](repeating: 0, count: frameCount)
        var prev = [Float](repeating: 0, count: fft.binCount)
        var isFirst = true
        for f0 in 0..<frameCount {
            let off = f0 * hop
            let mag = fft.magnitudes(data[off..<(off + n)])
            var flux: Float = 0
            if !isFirst {
                for k in 0..<fft.binCount {
                    let d = mag[k] - prev[k]
                    if d > 0 { flux += d }
                }
            } else {
                isFirst = false
            }
            prev.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: mag, count: fft.binCount) }
            env[f0] = flux
        }
        return (env, sampleRate / Double(hop))
    }

    static func movingMean(_ a: [Float], window: Int) -> [Float] {
        let n = a.count
        guard n > 0 else { return [] }
        var pre = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { pre[i + 1] = pre[i] + Double(a[i]) }
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let lo = max(0, i - window)
            let hi = min(n, i + window + 1)
            out[i] = Float((pre[hi] - pre[lo]) / Double(hi - lo))
        }
        return out
    }

    // MARK: - 从包络里找拍点

    static func detect(env: [Float], frameRate: Double) -> BeatResult? {
        guard env.count > 16, frameRate > 1 else { return nil }

        // 高通（减局部均值）并整流
        let w = max(2, Int(0.20 * frameRate))
        let mean = movingMean(env, window: w)
        var nov = [Float](repeating: 0, count: env.count)
        var energy: Double = 0
        for i in 0..<env.count {
            let v = max(0, env[i] - mean[i])
            nov[i] = v
            energy += Double(v)
        }
        guard energy > 1e-6 else { return nil }   // 静音

        // 自相关估周期
        let bpmMin = 60.0, bpmMax = 200.0
        let lagMin = max(2, Int((60 / bpmMax) * frameRate))
        let lagMax = min(nov.count - 2, Int((60 / bpmMin) * frameRate))
        guard lagMax > lagMin else { return nil }

        var bestLag = lagMin
        var bestScore = -Double.infinity
        var scoreSum = 0.0
        var scoreCount = 0
        for lag in lagMin...lagMax {
            var s = 0.0
            let cnt = nov.count - lag
            guard cnt > 0 else { continue }
            for i in 0..<cnt { s += Double(nov[i]) * Double(nov[i + lag]) }
            s /= Double(cnt)
            scoreSum += s
            scoreCount += 1
            let bpm = 60 * frameRate / Double(lag)
            // 偏好 90~150 BPM，压低倍频 / 半频误判
            let prior = exp(-0.5 * pow((bpm - 120) / 55, 2))
            let sc = s * (0.55 + 0.45 * prior)
            if sc > bestScore { bestScore = sc; bestLag = lag }
        }
        guard scoreCount > 0, bestScore > 0 else { return nil }
        let strength = bestScore / (scoreSum / Double(scoreCount))

        // 相位对齐
        var bestPhase = 0
        var bestPhaseScore = -Double.infinity
        for ph in 0..<bestLag {
            var s = 0.0
            var i = ph
            while i < nov.count { s += Double(nov[i]); i += bestLag }
            if s > bestPhaseScore { bestPhaseScore = s; bestPhase = ph }
        }

        // 生成拍点网格，并吸附到附近的局部峰
        let snap = max(1, Int(0.07 * frameRate))
        var beats: [Double] = []
        var i = bestPhase
        while i < nov.count {
            var bi = i
            var bv = nov[i]
            let lo = max(0, i - snap), hi = min(nov.count - 1, i + snap)
            if lo <= hi {
                for k in lo...hi where nov[k] > bv { bv = nov[k]; bi = k }
            }
            beats.append(Double(bi) / frameRate)
            i += bestLag
        }
        beats.sort()
        guard beats.count >= 2 else { return nil }

        // BPM 必须和实际网格一致，否则会出现「显示 120 但拍点其实 1 秒一个」的误导
        let bpm = 60 * frameRate / Double(bestLag)

        // 强拍相位：每 4 拍里挑能量最大的那一相
        var phaseScore = [Double](repeating: 0, count: 4)
        for (idx, t) in beats.enumerated() {
            let fIdx = min(nov.count - 1, max(0, Int(t * frameRate)))
            phaseScore[idx % 4] += Double(nov[fIdx])
        }
        var downbeat = 0
        for k in 1..<4 where phaseScore[k] > phaseScore[downbeat] { downbeat = k }

        return BeatResult(beats: beats, bpm: bpm, downbeat: downbeat, strength: strength)
    }

    // MARK: - 兜底：用骨架运动能量反推节拍

    static func bodyScale(_ lm: [Float]) -> Float {
        let dx = lm[LM.rightShoulder * 4] - lm[LM.leftShoulder * 4]
        let dy = lm[LM.rightShoulder * 4 + 1] - lm[LM.leftShoulder * 4 + 1]
        let s = (dx * dx + dy * dy).squareRoot()
        return s > 1e-3 ? s : 0.1
    }

    /// 把不规则采样点重采样成固定帧率的包络
    static func resample(_ samples: [(t: Double, e: Float)], duration: Double, rate: Double) -> [Float]? {
        guard samples.count >= 10 else { return nil }
        let s = samples.sorted { $0.t < $1.t }
        let span = s[s.count - 1].t - s[0].t
        guard span >= 2 else { return nil }
        var peak: Float = 0
        for p in s { peak = max(peak, p.e) }
        guard peak > 1e-6 else { return nil }

        let n = max(2, Int(ceil(duration * rate)))
        var env = [Float](repeating: 0, count: n)
        var j = 0
        for i in 0..<n {
            let t = Double(i) / rate
            while j < s.count - 2 && s[j + 1].t < t { j += 1 }
            let a = s[j], b = s[j + 1]
            let dt = b.t - a.t
            let w = dt > 1e-6 ? min(1, max(0, (t - a.t) / dt)) : 0
            env[i] = a.e * Float(1 - w) + b.e * Float(w)
        }
        return env
    }

    static func motionEnvelope(frames: [PoseFrame], duration: Double, rate: Double) -> [Float]? {
        guard frames.count >= 20 else { return nil }
        var pts: [(t: Double, e: Float)] = []
        for i in 1..<frames.count {
            let a = frames[i - 1], b = frames[i]
            let dt = b.t - a.t
            guard dt > 1e-3, dt <= 0.4 else { continue }
            var sum: Float = 0
            var n = 0
            for k in LM.motionJoints {
                let o = k * LM.stride
                guard a.lm[o + 3] >= 0.3, b.lm[o + 3] >= 0.3 else { continue }
                let dx = b.lm[o] - a.lm[o]
                let dy = b.lm[o + 1] - a.lm[o + 1]
                sum += (dx * dx + dy * dy).squareRoot()
                n += 1
            }
            guard n > 0 else { continue }
            let e = (sum / Float(n)) / bodyScale(b.lm) / Float(dt)
            pts.append(((a.t + b.t) / 2, e))
        }
        return resample(pts, duration: duration, rate: rate)
    }

    // MARK: - 分段

    static func beatTimes(in seg: Segment) -> [Double] {
        if !seg.beats.isEmpty { return seg.beats }
        var out: [Double] = []
        var t = seg.start
        while t < seg.end { out.append(t); t += 0.5 }
        return out
    }

    static func fallbackSegments(duration: Double) -> [Segment] {
        let step = max(2.0, duration / max(1, (duration / 4).rounded()))
        var segs: [Segment] = []
        var i = 0
        var t = 0.0
        while t < duration - 0.05 {
            segs.append(Segment(index: i, start: t, end: min(duration, t + step), beats: []))
            t += step
            i += 1
        }
        return segs
    }

    static func buildSegments(beats: [Double], phraseBeats: Int, downbeat: Int, duration: Double) -> [Segment] {
        guard !beats.isEmpty else { return fallbackSegments(duration: duration) }

        var startIdx = downbeat % 4
        while startIdx < beats.count && (startIdx % 4) != (downbeat % 4) { startIdx += 1 }
        if startIdx >= beats.count { startIdx = 0 }

        var segs: [Segment] = []
        var idx = 0
        if startIdx > 0, beats[startIdx] > 0.35 {
            segs.append(Segment(index: idx, start: 0, end: beats[startIdx],
                                beats: Array(beats[0..<startIdx])))
            idx += 1
        }
        var k = startIdx
        while k < beats.count {
            let a = beats[k]
            let b = (k + phraseBeats < beats.count) ? beats[k + phraseBeats] : duration
            if b - a < 0.4 { break }
            let end = min(beats.count, k + phraseBeats)
            segs.append(Segment(index: idx, start: a, end: b, beats: Array(beats[k..<end])))
            idx += 1
            k += phraseBeats
        }
        if segs.isEmpty { return fallbackSegments(duration: duration) }
        for n in 0..<segs.count { segs[n].index = n }
        return segs
    }
}
