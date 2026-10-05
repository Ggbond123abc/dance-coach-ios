import Foundation
import CoreGraphics
import SwiftUI

/// 把「一个身体」抽象成坐标系：原点 = 髋部中点，长度单位 = 躯干长。
/// 这样比对结果和你在画面里的位置、远近、身材大小都无关。
struct BodyFrame {
    var shoulder: CGPoint
    var hip: CGPoint
    var scale: CGFloat
}

/// 纯数学，和网页版的实现一一对应。
enum PoseMath {

    static let minVisible: CGFloat = 0.30

    @inline(__always)
    static func point(_ lm: [Float], _ i: Int, _ w: CGFloat, _ h: CGFloat) -> PosePoint {
        let o = i * LM.stride
        guard o + 3 < lm.count else { return PosePoint(x: 0, y: 0, v: 0) }
        return PosePoint(x: CGFloat(lm[o]) * w, y: CGFloat(lm[o + 1]) * h, v: CGFloat(lm[o + 3]))
    }

    /// 两个点的中点（任意一个不可见就返回 nil）
    static func mid(_ lm: [Float], _ a: Int, _ b: Int, _ w: CGFloat, _ h: CGFloat) -> CGPoint? {
        let p = point(lm, a, w, h)
        let q = point(lm, b, w, h)
        guard p.v >= minVisible, q.v >= minVisible else { return nil }
        return CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)
    }

    /// 以 b 为顶点的夹角（度）
    static func angleAt(_ lm: [Float], _ a: Int, _ b: Int, _ c: Int, _ w: CGFloat, _ h: CGFloat) -> CGFloat? {
        let p = point(lm, a, w, h), q = point(lm, b, w, h), r = point(lm, c, w, h)
        guard p.v >= minVisible, q.v >= minVisible, r.v >= minVisible else { return nil }
        let ax = p.x - q.x, ay = p.y - q.y
        let bx = r.x - q.x, by = r.y - q.y
        let ma = (ax * ax + ay * ay).squareRoot()
        let mb = (bx * bx + by * by).squareRoot()
        guard ma > 2, mb > 2 else { return nil }
        let c0 = max(-1, min(1, (ax * bx + ay * by) / (ma * mb)))
        return acos(c0) * 180 / .pi
    }

    static func frameOf(_ lm: [Float], _ w: CGFloat, _ h: CGFloat) -> BodyFrame? {
        guard let sh = mid(lm, LM.leftShoulder, LM.rightShoulder, w, h),
              let hp = mid(lm, LM.leftHip, LM.rightHip, w, h) else { return nil }
        let scale = hypot(sh.x - hp.x, sh.y - hp.y)
        guard scale >= 5 else { return nil }
        return BodyFrame(shoulder: sh, hip: hp, scale: scale)
    }

    /// 朝向对齐最多允许转 35°，再多就属于「站错方向了」，不能靠对齐硬掰。
    static let maxRotationDeg: CGFloat = 35

    /// 把参考骨架搬进用户的身体坐标系（平移 + 等比缩放 + 有限旋转）。
    /// 返回的坐标是「用户画面」的归一化坐标，可以直接画。
    static func alignRefToUser(ref: [Float], refW: CGFloat, refH: CGFloat,
                               user: BodyFrame, camW: CGFloat, camH: CGFloat)
        -> (lm: [Float], angleDeg: CGFloat)? {

        guard refW > 0, refH > 0, camW > 0, camH > 0,
              let rf = frameOf(ref, refW, refH) else { return nil }

        let s = user.scale / rf.scale
        var d = atan2(user.shoulder.y - user.hip.y, user.shoulder.x - user.hip.x)
              - atan2(rf.shoulder.y - rf.hip.y, rf.shoulder.x - rf.hip.x)
        while d > .pi { d -= 2 * .pi }
        while d < -.pi { d += 2 * .pi }
        let rawDeg = d * 180 / .pi
        let cap = maxRotationDeg * .pi / 180
        let dc = max(-cap, min(cap, d))
        let cosT = cos(dc), sinT = sin(dc)

        var out = emptyLandmarks()
        for i in 0..<LM.count {
            let o = i * LM.stride
            let vx = CGFloat(ref[o]) * refW - rf.hip.x
            let vy = CGFloat(ref[o + 1]) * refH - rf.hip.y
            let rx = vx * cosT - vy * sinT
            let ry = vx * sinT + vy * cosT
            out[o] = Float((user.hip.x + rx * s) / camW)
            out[o + 1] = Float((user.hip.y + ry * s) / camH)
            out[o + 2] = 0
            out[o + 3] = ref[o + 3]
        }
        return (out, rawDeg)
    }

    /// 把骨架整体旋转成「躯干朝上」。
    ///
    /// 摄像头画面和参考视频的画面方向不一定一致（前置摄像头竖屏拍到的
    /// 缓冲是横的），不先摆正的话，后面那个 35° 的对齐上限会一直被顶住，
    /// 每一帧都会被判成「姿势全错、0 分」。摆正之后这个比对就跟
    /// 手机怎么拿、视频怎么拍都无关了。
    static func upright(_ lm: [Float], _ w: CGFloat, _ h: CGFloat) -> [Float]? {
        guard w > 0, h > 0, let f = frameOf(lm, w, h) else { return nil }
        let a = atan2(f.shoulder.y - f.hip.y, f.shoulder.x - f.hip.x)
        let t = -CGFloat.pi / 2 - a
        let c = cos(t), s = sin(t)
        var out = emptyLandmarks()
        for i in 0..<LM.count {
            let o = i * LM.stride
            let vx = CGFloat(lm[o]) * w - f.hip.x
            let vy = CGFloat(lm[o + 1]) * h - f.hip.y
            out[o] = Float((f.hip.x + vx * c - vy * s) / w)
            out[o + 1] = Float((f.hip.y + vx * s + vy * c) / h)
            out[o + 2] = 0
            out[o + 3] = lm[o + 3]
        }
        return out
    }

    /// 正面朝镜头时，解剖学左肩出现在画面右侧（x 更大）；背对镜头则相反。
    /// 这是单目相机下唯一可靠判「朝哪边」的信号。
    static func facingSign(_ lm: [Float], _ w: CGFloat, _ h: CGFloat) -> Int? {
        let l = point(lm, LM.leftShoulder, w, h)
        let r = point(lm, LM.rightShoulder, w, h)
        guard l.v >= minVisible, r.v >= minVisible, abs(l.x - r.x) > 3 else { return nil }
        return l.x > r.x ? 1 : -1
    }

    /// 逐关节误差，单位是「躯干长」。这样不同身材、不同远近都可比。
    static func poseError(user: [Float], refAligned: [Float], userFrame: BodyFrame,
                          camW: CGFloat, camH: CGFloat)
        -> (mean: CGFloat, per: [Int: CGFloat], n: Int)? {

        var sum: CGFloat = 0
        var n = 0
        var per: [Int: CGFloat] = [:]
        for j in LM.scoreJoints {
            let u = point(user, j, camW, camH)
            let r = point(refAligned, j, camW, camH)
            guard u.v >= 0.35, r.v >= 0.30 else { continue }
            let d = hypot(u.x - r.x, u.y - r.y) / userFrame.scale
            per[j] = d
            sum += d
            n += 1
        }
        guard n >= 6 else { return nil }
        return (sum / CGFloat(n), per, n)
    }

    /// 总分 = 整体像不像 + 最偏的那几个部位。
    /// 只看均值的话，12 个点错 1 个也才掉几分，明显偏松。
    static func score(mean: CGFloat, per: [Int: CGFloat]) -> Int? {
        let errs = LM.scoreJoints.compactMap { per[$0] }.sorted(by: >)
        guard !errs.isEmpty else { return nil }
        let top = errs.prefix(3)
        let top3 = top.reduce(0, +) / CGFloat(top.count)
        let s1 = max(0, 1 - mean / 0.60)
        let s2 = max(0, 1 - top3 / 0.30)
        return Int((100 * (0.4 * s1 + 0.6 * s2)).rounded())
    }

    /// 绿 → 黄 → 红
    static func errColor(_ e: CGFloat) -> Color {
        let t = max(0, min(1, e / 0.30))
        return Color(red: Double(0.247 + (0.973 - 0.247) * t),
                     green: Double(0.725 + (0.318 - 0.725) * t),
                     blue: Double(0.314 + (0.286 - 0.314) * t))
    }

    static func scoreColor(_ s: Int) -> Color {
        if s >= 80 { return Color(red: 0.247, green: 0.725, blue: 0.314) }
        if s >= 55 { return Color(red: 0.824, green: 0.600, blue: 0.133) }
        return Color(red: 0.973, green: 0.318, blue: 0.286)
    }
}

/// 区间统计
enum Stats {
    static func range(_ values: [CGFloat]) -> (lo: CGFloat, hi: CGFloat, span: CGFloat)? {
        guard values.count >= 4 else { return nil }
        guard let lo = values.min(), let hi = values.max() else { return nil }
        return (lo, hi, hi - lo)
    }

    /// 折线总长度；单步超过 maxStep 的当作关键点跳变丢掉
    static func pathLength(_ pts: [CGPoint], maxStep: CGFloat) -> (d: CGFloat, n: Int) {
        var d: CGFloat = 0
        var n = 0
        for i in 1..<max(1, pts.count) {
            let s = hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)
            if maxStep > 0 && s > maxStep { continue }
            d += s
            n += 1
        }
        return (d, n)
    }
}
