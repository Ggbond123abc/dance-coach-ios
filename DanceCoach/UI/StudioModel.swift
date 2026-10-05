import Foundation
import AVFoundation
import SwiftUI
import Combine
import CoreGraphics

final class StudioModel: ObservableObject {

    enum Stage { case empty, analyzing, ready }

    enum ViewMode: String, CaseIterable, Identifiable {
        case both, skeleton, video
        var id: String { rawValue }
        var label: String {
            switch self {
            case .both: return "叠加"
            case .skeleton: return "只看骨架"
            case .video: return "只看视频"
            }
        }
    }

    enum FocusMode: String, CaseIterable, Identifiable {
        case full, lower, upper
        var id: String { rawValue }
        var label: String {
            switch self {
            case .full: return "全身"
            case .lower: return "下半身"
            case .upper: return "上半身"
            }
        }
        var hint: String {
            switch self {
            case .full: return "全身"
            case .lower: return "下半身 · 放大看脚步"
            case .upper: return "上半身 · 放大看手"
            }
        }
    }

    // MARK: - 状态

    @Published var stage: Stage = .empty
    @Published var sourceName = ""
    @Published var info: VideoInfo?
    @Published var frames: [PoseFrame] = []
    @Published var sampledFrames = 0
    @Published var detectedFrames = 0
    @Published var poseOK = true

    @Published var beats: [Double] = []
    @Published var bpm: Double = 0
    @Published var beatMode: BeatMode = .none
    @Published var downbeat = 0
    @Published var phraseBeats = 8

    @Published var segments: [Segment] = []
    @Published var selected = -1
    @Published var loopStartBeat = 1
    @Published var loopEndBeat = 1

    @Published var isAnalyzing = false
    @Published var progress: Double = 0
    @Published var logLines: [String] = []
    @Published var errorText: String?

    @Published var diagItems: [DiagItem] = []
    @Published var diagNote = ""

    // 练习
    @Published var isPlaying = false
    @Published var speed: Float = 0.5
    @Published var loopEnabled = true
    @Published var mirror = false
    @Published var viewMode: ViewMode = .both
    @Published var focusMode: FocusMode = .full
    @Published var trailEnabled = true
    @Published var clickEnabled = true
    @Published var currentTime: Double = 0
    @Published var currentBeatLabel = "—"

    // 摄像头
    @Published var cameraOn = false
    @Published var cameraMatch: MatchResult?
    @Published var cameraScore: Int?
    @Published var cameraHint = "站到画面里，让全身（连脚）都进画幅。"
    @Published var cameraFacingWarn = false

    let player = AVPlayer()
    let camera = CameraTracker()
    private let clicker = ClickPlayer()
    private var timeObserver: Any?
    private var lastBeatIndex = -99
    private var videoURL: URL?
    private var focusCacheKey = ""
    private var focusCacheBox: CGRect?

    private let minVisibleConfidence: CGFloat = 0.30

    // MARK: - 载入

    func load(url: URL, name: String) {
        reset()
        videoURL = url
        sourceName = name
        Task {
            do {
                let info = try await MediaIO.loadInfo(url: url)
                self.info = info
                let item = AVPlayerItem(url: url)
                self.player.replaceCurrentItem(with: item)
                self.player.actionAtItemEnd = .pause
                self.installTimeObserver()
                self.stage = .ready
                self.append("已载入：\(name)  时长 \(Self.fmt(info.duration))  分辨率 \(Int(info.displaySize.width))×\(Int(info.displaySize.height))")
                if info.duration > 600 {
                    self.append("⚠️ 视频超过 10 分钟，分析会比较久，建议先剪出要学的那一段。")
                }
            } catch {
                self.errorText = error.localizedDescription
                self.append("❌ " + error.localizedDescription)
            }
        }
    }

    func reset() {
        player.pause()
        isPlaying = false
        frames = []
        beats = []
        bpm = 0
        beatMode = .none
        segments = []
        selected = -1
        diagItems = []
        diagNote = ""
        currentTime = 0
        cameraMatch = nil
        cameraScore = nil
        lastBeatIndex = -99
    }

    private func installTimeObserver() {
        if let o = timeObserver { player.removeTimeObserver(o) }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.03, preferredTimescale: 600),
            queue: .main
        ) { [weak self] t in
            self?.tick(t.seconds)
        }
    }

    // MARK: - 分析

    func analyze() {
        guard let url = videoURL, let info = info else { return }
        guard !isAnalyzing else { return }
        isAnalyzing = true
        stage = .analyzing
        progress = 0
        logLines = []
        frames = []
        beats = []
        segments = []
        selected = -1
        diagItems = []
        append("开始分析…")
        stopCamera()
        player.pause()
        isPlaying = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var poseResult: Result<PoseExtraction, Error>
            do {
                let e = try MediaIO.extractPoses(url: url, info: info) { p in
                    DispatchQueue.main.async { self.progress = p * 0.7 }
                }
                poseResult = .success(e)
            } catch {
                poseResult = .failure(error)
            }
            DispatchQueue.main.async {
                self.applyPose(poseResult, url: url, info: info)
            }
        }
    }

    private func applyPose(_ result: Result<PoseExtraction, Error>, url: URL, info: VideoInfo) {
        switch result {
        case .failure(let e):
            isAnalyzing = false
            stage = .ready
            append("❌ 骨架提取失败：" + e.localizedDescription)
            errorText = e.localizedDescription
        case .success(let ex):
            frames = ex.frames
            sampledFrames = ex.sampled
            detectedFrames = ex.detected
            progress = 0.72
            let rate = ex.detected > 0 ? Double(ex.detected) / max(1, info.duration) : 0
            append(String(format: "骨架采样完成：%d 帧有姿态（占 %d 帧的 %.0f%%），约 %.1f 帧/秒",
                          ex.detected, ex.sampled,
                          ex.sampled > 0 ? 100 * Double(ex.detected) / Double(ex.sampled) : 0, rate))
            poseOK = ex.detected >= 15
            if !poseOK {
                append("⚠️ 几乎没检测到人体骨架：画面里可能没有人、人物太小、或动作太快拖影严重。")
                append("   → 骨架叠加 / 实时比对会不可用，但「音乐节拍 + 自动分段 + 慢放循环」依然有效。")
            }
            detectBeats(url: url, info: info)
        }
    }

    private func detectBeats(url: URL, info: VideoInfo) {
        append("离线解码音频…")
        let framesCopy = frames
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var found: BeatResult?
            var mode: BeatMode = .none
            var note = ""

            do {
                let pcm = try MediaIO.monoPCM(url: url)
                if let env = BeatDetector.onsetEnvelope(pcm, sampleRate: 22050),
                   let r = BeatDetector.detect(env: env.env, frameRate: env.frameRate) {
                    found = r
                    mode = .audio
                } else {
                    note = "离线解码成功，但没找到稳定节拍（鼓点太弱，或音轨被剪过）。"
                }
            } catch {
                note = "离线音频不可用：" + error.localizedDescription
            }

            // 兜底：用骨架运动能量反推节拍。舞蹈动作本来就踩在音乐上。
            if found == nil {
                if let env = BeatDetector.motionEnvelope(frames: framesCopy,
                                                         duration: info.duration, rate: 100),
                   let r = BeatDetector.detect(env: env, frameRate: 100), r.strength >= 1.3 {
                    found = r
                    mode = .motion
                } else {
                    note += " 骨架运动能量里也没找到足够稳定的节奏。"
                }
            }

            DispatchQueue.main.async {
                if let r = found {
                    self.beats = r.beats
                    self.bpm = r.bpm
                    self.downbeat = r.downbeat
                    self.beatMode = mode
                    self.append(String(format: "✔ 找到 %d 个拍点，BPM ≈ %.1f（强拍相位 %d/4）%@",
                                       r.beats.count, r.bpm, r.downbeat,
                                       mode == .motion ? "（用骨架运动反推，没听音频）" : ""))
                } else {
                    self.beats = []
                    self.bpm = 0
                    self.beatMode = .none
                    self.append("⚠️ " + note)
                    self.append("提示：没有节拍时，分段只是等长的，练习时的「拍点提示」也会退化。")
                }
                self.rebuildSegments()
                self.progress = 1
                self.append("✔ 分析完成。选一段开始练。")
                self.isAnalyzing = false
            }
        }
    }

    // MARK: - 分段

    func rebuildSegments() {
        guard let info else { return }
        segments = BeatDetector.buildSegments(beats: beats, phraseBeats: phraseBeats,
                                              downbeat: downbeat, duration: info.duration)
        selected = segments.isEmpty ? -1 : 0
        loopStartBeat = 1
        loopEndBeat = max(1, BeatDetector.beatTimes(in: segments.first ?? Segment(index: 0, start: 0, end: 0, beats: [])).count)
        if selected >= 0 { selectSegment(selected) }
    }

    func selectSegment(_ index: Int) {
        guard index >= 0, index < segments.count else { return }
        selected = index
        loopStartBeat = 1
        loopEndBeat = max(1, BeatDetector.beatTimes(in: segments[index]).count)
        lastBeatIndex = -99
        player.pause()
        isPlaying = false
        seek(to: abRange.a)
        refreshDiagnostics()
    }

    var currentSegment: Segment? {
        guard selected >= 0, selected < segments.count else { return nil }
        return segments[selected]
    }

    /// 循环区间。默认整段，但可以精确到「从第几拍练到第几拍」。
    var abRange: (a: Double, b: Double) {
        guard let seg = currentSegment else { return (0, 0) }
        let times = BeatDetector.beatTimes(in: seg)
        guard !times.isEmpty else {
            return (seg.start, max(seg.start + 0.2, seg.end - 0.03))
        }
        let si = min(max(1, loopStartBeat), times.count) - 1
        let ei = min(max(loopStartBeat, loopEndBeat), times.count)
        let a = times[si]
        let b = ei >= times.count ? seg.end : times[ei]
        return (a, max(a + 0.08, b - 0.02))
    }

    var beatTimesInSegment: [Double] {
        guard let seg = currentSegment else { return [] }
        return BeatDetector.beatTimes(in: seg)
    }

    func loopOne() {
        loopEndBeat = loopStartBeat
        player.pause()
        isPlaying = false
        seek(to: abRange.a)
        lastBeatIndex = -99
    }

    func loopAll() {
        loopStartBeat = 1
        loopEndBeat = max(1, beatTimesInSegment.count)
        player.pause()
        isPlaying = false
        seek(to: abRange.a)
        lastBeatIndex = -99
    }

    func setLoopStart(_ beat: Int) {
        let n = max(1, beatTimesInSegment.count)
        loopStartBeat = min(max(1, beat), n)
        if loopEndBeat < loopStartBeat { loopEndBeat = loopStartBeat }
        player.pause()
        isPlaying = false
        seek(to: abRange.a)
        lastBeatIndex = -99
    }

    func setLoopEnd(_ beat: Int) {
        let n = max(1, beatTimesInSegment.count)
        loopEndBeat = min(max(loopStartBeat, beat), n)
    }

    /// 倍频（半拍 / 双拍）是节拍检测最典型的错误，给个一键修正的出口
    func scaleBeats(by factor: Double) {
        guard beats.count >= 2 else { return }
        var out: [Double] = []
        if factor > 1 {
            for (i, t) in beats.enumerated() {
                out.append(t)
                if i + 1 < beats.count { out.append((t + beats[i + 1]) / 2) }
            }
        } else {
            for (i, t) in beats.enumerated() where i % 2 == 0 { out.append(t) }
        }
        beats = out
        if out.count > 1 {
            let span = out[out.count - 1] - out[0]
            bpm = 60 / (span / Double(out.count - 1))
        }
        downbeat = 0
        rebuildSegments()
        append(String(format: "✔ 已手动修正节拍：BPM ≈ %.1f，共 %d 个拍点，切成 %d 段",
                      bpm, beats.count, segments.count))
    }

    func jumpBeat(_ dir: Int) {
        let times = beatTimesInSegment
        guard !times.isEmpty else { return }
        let t = player.currentTime().seconds
        var idx: Int
        if dir > 0 {
            idx = times.firstIndex(where: { $0 > t + 0.02 }) ?? 0
        } else {
            idx = -1
            for (i, b) in times.enumerated() where b < t - 0.02 { idx = i }
            if idx < 0 { idx = times.count - 1 }
        }
        player.pause()
        isPlaying = false
        setLoopStart(idx + 1)
    }

    func stepFrame(_ dir: Int) {
        guard !frames.isEmpty else { return }
        var i = nearestIndex(player.currentTime().seconds)
        let t = player.currentTime().seconds
        if i > 0, abs(frames[i - 1].t - t) < abs(frames[i].t - t) { i -= 1 }
        i = min(max(0, i + dir), frames.count - 1)
        player.pause()
        isPlaying = false
        seek(to: frames[i].t)
    }

    private func nearestIndex(_ t: Double) -> Int {
        guard !frames.isEmpty else { return 0 }
        var lo = 0, hi = frames.count - 1
        while lo < hi {
            let mid = (lo + hi) >> 1
            if frames[mid].t < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    func nearestFrame(_ t: Double) -> PoseFrame? {
        guard !frames.isEmpty else { return nil }
        let i = nearestIndex(t)
        var best = frames[i]
        if i > 0, abs(frames[i - 1].t - t) < abs(best.t - t) { best = frames[i - 1] }
        return best
    }

    /// 取 [from, to] 之间的帧。二分定位，别在每帧重绘里全表扫描。
    func frameRange(from: Double, to: Double) -> ArraySlice<PoseFrame> {
        guard !frames.isEmpty else { return frames[0..<0] }
        var lo = 0, hi = frames.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if frames[mid].t < from { lo = mid + 1 } else { hi = mid }
        }
        let start = lo
        var a = start, b = frames.count
        while a < b {
            let mid = (a + b) >> 1
            if frames[mid].t <= to { a = mid + 1 } else { b = mid }
        }
        return frames[start..<a]
    }

    // MARK: - 播放

    func seek(to t: Double) {
        guard let info else { return }
        let clamped = min(max(0, t), max(0, info.duration - 0.01))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlay() {
        if isPlaying {
            player.pause()
            isPlaying = false
            return
        }
        clicker.start()
        let ab = abRange
        let t = player.currentTime().seconds
        if t < ab.a - 0.05 || t > ab.b + 0.05 { seek(to: ab.a) }
        player.play()
        player.rate = speed
        isPlaying = true
        lastBeatIndex = -99
        camera.reset()
    }

    func applySpeed() {
        if isPlaying { player.rate = speed }
    }

    private func tick(_ t: Double) {
        currentTime = t
        guard let info else { return }

        if loopEnabled, currentSegment != nil {
            let ab = abRange
            if t >= ab.b - 0.005 || t < ab.a - 0.05 {
                seek(to: ab.a)
                lastBeatIndex = -99
            }
        }

        // 拍点提示
        let times = beatTimesInSegment
        if !times.isEmpty {
            var idx = -1
            for (i, b) in times.enumerated() where b <= t + 0.005 { idx = i }
            if idx >= 0, idx != lastBeatIndex {
                lastBeatIndex = idx
                if clickEnabled, isPlaying { clicker.click(strong: idx % 4 == 0) }
                currentBeatLabel = "第 \(idx + 1) / \(times.count) 拍" + (idx % 4 == 0 ? " · 强拍" : "")
            }
        } else {
            currentBeatLabel = "—"
        }

        updateCameraMatch()

        if t >= info.duration - 0.02, isPlaying {
            player.pause()
            isPlaying = false
        }
    }

    // MARK: - 视觉提示（放大概焦 / 脚部轨迹）

    /// 算出「这一段里某个部位的活动范围」，用来把画面放大到那块。
    /// 结果按（分段 + 模式 + 帧数）缓存 —— 每帧重绘都会问它好几次。
    func focusBox() -> CGRect? {
        guard let seg = currentSegment, focusMode != .full else { return nil }
        let key = "\(seg.index)|\(focusMode.rawValue)|\(frames.count)"
        if key == focusCacheKey { return focusCacheBox }
        focusCacheKey = key
        let box = computeFocusBox(seg: seg)
        focusCacheBox = box
        return box
    }

    private func computeFocusBox(seg: Segment) -> CGRect? {
        let joints = focusMode == .lower ? LM.focusLower : LM.focusUpper
        let size = info?.displaySize ?? .zero
        let fr = Diagnostics.frames(in: seg, from: frames)
        guard !fr.isEmpty else { return nil }
        let w = max(1, size.width), h = max(1, size.height)

        var x0: CGFloat = 1, y0: CGFloat = 1, x1: CGFloat = 0, y1: CGFloat = 0
        var n = 0
        for f in fr {
            for k in joints {
                let p = PoseMath.point(f.lm, k, w, h)
                guard p.v >= 0.3 else { continue }
                x0 = min(x0, p.x / w); x1 = max(x1, p.x / w)
                y0 = min(y0, p.y / h); y1 = max(y1, p.y / h)
                n += 1
            }
        }
        guard n >= 20, x1 > x0, y1 > y0 else { return nil }

        let padX = max(0.05, (x1 - x0) * 0.20)
        let padY = max(0.07, (y1 - y0) * 0.22)
        var bw = (x1 - x0) + padX * 2
        var bh = (y1 - y0) + padY * 2
        let cx = (x0 - padX) + bw / 2
        let cy = (y0 - padY) + bh / 2
        // 归一化坐标里 x 按宽度、y 按高度，所以「像素宽高比不变」等价于宽高相等
        let side = min(1, max(bw, bh))
        bw = side; bh = side
        let bx = max(0, min(1 - side, cx - side / 2))
        let by = max(0, min(1 - side, cy - side / 2))
        return CGRect(x: bx, y: by, width: bw, height: bh)
    }

    /// 放大 + 平移，让 focusBox 正好铺满画面。
    /// 配合 .scaleEffect(scale, anchor: .topLeading) 使用：
    /// 缩放中心在视图自己的左上角，而视图是居中摆放的，所以要补一项 (1-k)/2。
    var focusTransform: (scale: CGFloat, offset: CGSize) {
        guard let b = focusBox(), b.width > 0 else { return (1, .zero) }
        let k = 1 / b.width
        return (k, CGSize(width: (1 - k) / 2 - b.minX * k,
                          height: (1 - k) / 2 - b.minY * k))
    }

    // MARK: - 诊断

    func refreshDiagnostics() {
        guard let seg = currentSegment, !frames.isEmpty, let info else {
            diagItems = []
            diagNote = "先选一个分段。"
            return
        }
        let r = Diagnostics.analyze(seg: seg, all: frames, videoSize: info.displaySize)
        diagItems = r.items
        diagNote = r.items.isEmpty ? r.note
            : "以上是程序根据骨架自动估算的，提示「这一段在练什么、哪里容易做错」，不能替代老师对具体动作的判断。"
    }

    // MARK: - 摄像头

    func startCamera() {
        camera.start()
        cameraOn = true
        cameraScore = nil
        cameraMatch = nil
        append("✔ 摄像头已开启。把全身（连脚）放进画面，然后点播放跟着跳。")
        append("  摄像头画面是镜像的（像照镜子）。分析时摄像头会自动关掉，腾出性能给骨架提取。")
    }

    func stopCamera() {
        camera.stop()
        cameraOn = false
        cameraMatch = nil
        cameraScore = nil
        cameraHint = "站到画面里，让全身（连脚）都进画幅。"
    }

    private func updateCameraMatch() {
        guard cameraOn else { return }
        guard let userLm = camera.latest, let info else {
            cameraMatch = nil
            cameraHint = "没检测到人：退后一点，让全身（连脚）都进画面，光线足一点。"
            return
        }
        let camSize = camera.bufferSize
        guard camSize.width > 0, let uf = PoseMath.frameOf(userLm, camSize.width, camSize.height) else {
            cameraMatch = nil
            cameraHint = "看到你了，但站得太远或太近，先让全身进画面。"
            return
        }
        guard let m = PoseComparator.bestMatch(user: userLm, userFrame: uf,
                                               now: player.currentTime().seconds,
                                               frames: frames,
                                               refSize: info.displaySize,
                                               camSize: camSize) else {
            cameraMatch = nil
            cameraHint = "参考动作在这附近没有可用的骨架帧。"
            return
        }
        cameraMatch = m
        if let raw = m.score {
            cameraScore = cameraScore == nil ? raw : Int(Double(cameraScore!) * 0.75 + Double(raw) * 0.25)
        }
        cameraFacingWarn = m.facingMismatch
        if m.facingMismatch {
            cameraHint = "⚠️ 你和参考的左右方向是反的（参考背对镜头，或者你背对镜头）。分数低是这个原因，先转个身。"
        } else if m.worst.isEmpty {
            cameraHint = "身上各点跟得都还不错 👍"
        } else {
            cameraHint = "最偏的部位：" + m.worst.joined(separator: "、")
        }
    }

    // MARK: - 工具

    func append(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        logLines.append("[\(f.string(from: Date()))] \(s)")
        if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
    }

    static func fmt(_ s: Double) -> String {
        guard s.isFinite, s >= 0 else { return "—" }
        let m = Int(s) / 60
        let sec = s - Double(m * 60)
        return String(format: "%d:%05.2f", m, sec)
    }
}
