import Foundation
import CoreGraphics

/// 关键点编号沿用 MediaPipe 的 33 点体系。
///
/// 注意：Apple Vision 只给 19 个点（没有脚趾/脚跟/手指），
/// 缺失的点我们会写成 visibility = 0，下面所有算法都遵守同一条规矩：
/// **可见度不足就跳过**，所以 19 点也能正常跑，只是脚部细节和手指拿不到。
enum LM {
    static let nose = 0
    static let leftShoulder = 11
    static let rightShoulder = 12
    static let leftElbow = 13
    static let rightElbow = 14
    static let leftWrist = 15
    static let rightWrist = 16
    static let leftHip = 23
    static let rightHip = 24
    static let leftKnee = 25
    static let rightKnee = 26
    static let leftAnkle = 27
    static let rightAnkle = 28
    static let leftHeel = 29
    static let rightHeel = 30
    static let leftFootIndex = 31
    static let rightFootIndex = 32

    static let count = 33
    /// 每个点占 4 个 Float：x, y, z, visibility
    static let stride = 4

    static let connections: [(Int, Int)] = [
        (0, 1), (1, 2), (2, 3), (3, 7), (0, 4), (4, 5), (5, 6), (6, 8), (9, 10),
        (11, 12), (11, 13), (13, 15), (15, 17), (15, 19), (15, 21), (17, 19),
        (12, 14), (14, 16), (16, 18), (16, 20), (16, 22), (18, 20),
        (11, 23), (12, 24), (23, 24),
        (23, 25), (25, 27), (27, 29), (27, 31), (29, 31),
        (24, 26), (26, 28), (28, 30), (28, 32), (30, 32),
        (0, 9), (0, 10)
    ]

    /// 打分只用这些点：脸和手指抖动太大，脚趾在 Vision 上也拿不到
    static let scoreJoints = [11, 12, 13, 14, 15, 16, 23, 24, 25, 26, 27, 28]
    /// 用来估计「动作量」的点
    static let motionJoints = [0, 11, 12, 13, 14, 15, 16, 23, 24, 25, 26, 27, 28, 31, 32]

    static let names: [Int: String] = [
        11: "左肩", 12: "右肩", 13: "左肘", 14: "右肘", 15: "左手", 16: "右手",
        23: "左胯", 24: "右胯", 25: "左膝", 26: "右膝", 27: "左脚", 28: "右脚"
    ]

    static let focusLower = [23, 24, 25, 26, 27, 28, 29, 30, 31, 32]
    static let focusUpper = [0, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22]
}

/// 一帧骨架。`lm` 是 33 × 4 的扁平数组（归一化坐标 0~1 + 可见度）。
struct PoseFrame {
    var t: Double
    var lm: [Float]

    init(t: Double, lm: [Float]) {
        self.t = t
        self.lm = lm
    }
}

@inline(__always)
func emptyLandmarks() -> [Float] {
    [Float](repeating: 0, count: LM.count * LM.stride)
}

/// 归一化坐标系里的一个点
struct PosePoint {
    var x: CGFloat
    var y: CGFloat
    var v: CGFloat
}

/// 一个动作段落
struct Segment: Identifiable, Equatable {
    var id: Int { index }
    var index: Int
    var start: Double
    var end: Double
    var beats: [Double]

    static func == (a: Segment, b: Segment) -> Bool {
        a.index == b.index && a.start == b.start && a.end == b.end
    }
}

enum BeatMode: String {
    case none = "none"
    case audio = "audio"          // 离线解码音频 + 谱通量
    case liveAudio = "liveAudio"  // 播放时实时采集音量包络
    case motion = "motion"        // 用骨架运动能量反推

    var label: String {
        switch self {
        case .none: return "等长兜底分段"
        case .audio, .liveAudio: return "音乐节拍分段"
        case .motion: return "骨架运动节拍"
        }
    }
}

/// 分析出来的一条提示
struct DiagItem: Identifiable {
    enum Level: String { case ok, warn, risk }
    let id = UUID()
    var title: String
    var value: String
    var level: Level
    /// 已经带好简单标记（<b>…</b>）的说明文字
    var advice: String
}

extension Array where Element == Float {
    /// 取第 i 个点的归一化坐标
    @inline(__always)
    func pt(_ i: Int) -> PosePoint {
        let o = i * LM.stride
        guard o + 3 < count else { return PosePoint(x: 0, y: 0, v: 0) }
        return PosePoint(x: CGFloat(self[o]), y: CGFloat(self[o + 1]), v: CGFloat(self[o + 3]))
    }
}
