import Foundation
import CoreGraphics

/// 一次实时比对的结果
struct MatchResult {
    var mean: CGFloat
    var per: [Int: CGFloat]
    var offset: Double
    /// 左右方向是否和参考相反（参考背对镜头 / 你背对镜头）
    var facingMismatch: Bool
    var refLm: [Float]
    var refTime: Double
    var score: Int?
    var worst: [String]
}

/// 把用户的实时骨架和参考动作对齐后逐关节比对。
///
/// 关键点：比对在 ±0.35 秒的窗口里找最合拍的参考帧。
/// 这样「没跟上拍」和「动作做错了」才不会互相污染 ——
/// 前者体现在 offset，后者体现在 mean。
enum PoseComparator {

    static let window: Double = 0.35

    static func bestMatch(user rawUser: [Float],
                          userFrame: BodyFrame,
                          now: Double,
                          frames: [PoseFrame],
                          refSize: CGSize,
                          camSize: CGSize) -> MatchResult? {
        guard !frames.isEmpty, refSize.width > 0, refSize.height > 0,
              camSize.width > 0, camSize.height > 0 else { return nil }

        // 先摆正，让比对只关心姿势本身
        let user = PoseMath.upright(rawUser, camSize.width, camSize.height) ?? rawUser
        let userFacing = PoseMath.facingSign(user, camSize.width, camSize.height)

        // 二分找到窗口起点
        var lo = 0, hi = frames.count - 1
        let from = max(0, now - window)
        while lo < hi {
            let mid = (lo + hi) >> 1
            if frames[mid].t < from { lo = mid + 1 } else { hi = mid }
        }

        var best: MatchResult?
        var bestCost = CGFloat.infinity

        var i = lo
        while i < frames.count {
            let f = frames[i]
            if f.t > now + window { break }
            i += 1

            guard let aligned = PoseMath.alignRefToUser(ref: f.lm,
                                                        refW: refSize.width,
                                                        refH: refSize.height,
                                                        user: userFrame,
                                                        camW: camSize.width,
                                                        camH: camSize.height) else { continue }
            guard let err = PoseMath.poseError(user: user,
                                               refAligned: aligned.lm,
                                               userFrame: userFrame,
                                               camW: camSize.width,
                                               camH: camSize.height) else { continue }

            let offset = now - f.t
            // 惩罚项只为「打平」：姿势几乎静止时窗口里很多帧都一样，
            // 没有它就会永远报最大偏差。0.02/秒 约等于 1 分，不会盖过真实信号。
            let cost = err.mean + CGFloat(abs(offset)) * 0.02
            if cost < bestCost {
                bestCost = cost
                let worst = err.per
                    .filter { $0.value > 0.12 }
                    .sorted { $0.value > $1.value }
                    .prefix(3)
                    .map { LM.names[$0.key] ?? "关节\($0.key)" }
                let refFacing = PoseMath.facingSign(f.lm, refSize.width, refSize.height)
                best = MatchResult(mean: err.mean,
                                   per: err.per,
                                   offset: offset,
                                   facingMismatch: userFacing != nil && refFacing != nil && userFacing != refFacing,
                                   refLm: aligned.lm,
                                   refTime: f.t,
                                   score: PoseMath.score(mean: err.mean, per: err.per),
                                   worst: Array(worst))
            }
        }
        return best
    }
}
