import Foundation
import CoreGraphics

/// 动作要点 / 易错点。
///
/// 思路和网页版一致：先从骨架里量出「这一段在练什么」，
/// 再针对量出来的结果给对应的常见错误提醒。
/// 所有阈值都是经验值，界面上会明确写「自动估算，仅供参考」。
enum Diagnostics {

    static func frames(in seg: Segment, from all: [PoseFrame]) -> [PoseFrame] {
        var lo = 0
        var hi = all.count - 1
        while lo < hi {
            let mid = (lo + hi) >> 1
            if all[mid].t < seg.start - 1e-6 { lo = mid + 1 } else { hi = mid }
        }
        var out: [PoseFrame] = []
        var i = lo
        while i < all.count, all[i].t <= seg.end + 1e-6 {
            out.append(all[i])
            i += 1
        }
        return out
    }

    private static func trail(_ frames: [PoseFrame], _ joint: Int, _ w: CGFloat, _ h: CGFloat) -> [CGPoint] {
        var out: [CGPoint] = []
        for f in frames {
            let p = PoseMath.point(f.lm, joint, w, h)
            guard p.v >= PoseMath.minVisible else { continue }
            out.append(CGPoint(x: p.x, y: p.y))
        }
        return out
    }

    private static func f(_ v: CGFloat, _ digits: Int = 0) -> String {
        String(format: "%.\(digits)f", Double(v))
    }

    // 注意：内部参数名不能叫 `frames`，否则会遮住上面的静态方法 `frames(in:from:)`
    static func analyze(seg: Segment, all allFrames: [PoseFrame], videoSize: CGSize) -> (items: [DiagItem], note: String) {
        let w = max(1, videoSize.width)
        let h = max(1, videoSize.height)
        let fr = frames(in: seg, from: allFrames)
        guard fr.count >= 10 else {
            return ([], "这一段的有效骨架帧太少，给不出可靠提示。")
        }

        // 用躯干长度做尺度基准，不同画幅 / 远近都能比较
        var torsos: [CGFloat] = []
        for f0 in fr {
            guard let s = PoseMath.mid(f0.lm, LM.leftShoulder, LM.rightShoulder, w, h),
                  let p = PoseMath.mid(f0.lm, LM.leftHip, LM.rightHip, w, h) else { continue }
            torsos.append(hypot(s.x - p.x, s.y - p.y))
        }
        guard torsos.count >= 6 else {
            return ([], "肩部 / 髋部关键点在这段画面里不稳定，没法做动作分析。")
        }
        torsos.sort()
        let scale = max(8, torsos[torsos.count / 2])

        var hipTrail: [CGPoint] = []
        var inverted = 0
        var torsoSeen = 0
        for f0 in fr {
            guard let p = PoseMath.mid(f0.lm, LM.leftHip, LM.rightHip, w, h) else { continue }
            hipTrail.append(p)
            if let s = PoseMath.mid(f0.lm, LM.leftShoulder, LM.rightShoulder, w, h) {
                torsoSeen += 1
                if p.y < s.y { inverted += 1 }
            }
        }
        guard hipTrail.count >= 8 else {
            return ([], "髋部关键点不可靠，没法做动作分析。")
        }

        var items: [DiagItem] = []
        func add(_ title: String, _ value: String, _ level: DiagItem.Level, _ advice: String) {
            items.append(DiagItem(title: title, value: value, level: level, advice: advice))
        }

        // 1) 动作速度
        var dist: CGFloat = 0
        if hipTrail.count > 1 {
            for i in 1..<hipTrail.count {
                let s = hypot(hipTrail[i].x - hipTrail[i - 1].x, hipTrail[i].y - hipTrail[i - 1].y)
                if s > scale * 1.5 { continue }
                dist += s
            }
        }
        let dReal = hipTrail.count > 1 ? (fr.last!.t - fr.first!.t) : 0
        let rate = dReal > 0.5 ? (dist / scale) / CGFloat(dReal) : 0
        if dReal > 0.5 {
            let fast = rate > 1.0, slow = rate < 0.35
            add("动作速度",
                "\(f(rate, 2)) 躯干长/秒\(fast ? "（偏快）" : slow ? "（偏慢）" : "（中等）")",
                .ok,
                fast
                ? "这段动作很密，原速基本跟不上。建议：<b>先在 0.25x 把每个落脚点定住</b>，能连着做 3 遍不卡，再往 0.5x → 0.75x 提。"
                : slow
                ? "这段很慢。慢动作最容易偷工减料——<b>慢不等于松</b>，起手和收手都要有明确的到位感。"
                : "速度适中，适合整段跟练。")
        }

        // 2) 重心上下起伏（律动强度）
        if let hy = Stats.range(hipTrail.map { $0.y }) {
            let r = hy.span / scale
            add("重心上下起伏", "振幅 \(f(r * 100))% 躯干长", r < 0.15 ? .warn : .ok,
                r < 0.15
                ? "这段几乎不上下起伏。常见错误是<b>用上半身去凑动作</b>，看起来像在原地比划。如果原动作靠律动带动，先把单纯的上下 bounce 练熟。"
                : "有明显起伏。注意<b>下沉要压在拍点上</b>，不要抢拍或拖拍。")
        }

        // 3) 重心左右移动
        if let hx = Stats.range(hipTrail.map { $0.x }) {
            let r = hx.span / scale
            add("重心左右移动", "范围 \(f(r * 100))% 躯干长", .ok,
                r < 0.25
                ? "基本在原地。注意别把重心坐死在一条腿上，<b>重心要能在两脚之间转移</b>，否则动作会发僵。"
                : "这段有横向位移。注意<b>脚先出去、重心再跟上</b>，别让上半身先倒过去。")
        }

        // 4) 膝盖屈伸
        var kneeAngles: [CGFloat] = []
        for f0 in fr {
            if let a = PoseMath.angleAt(f0.lm, LM.leftHip, LM.leftKnee, LM.leftAnkle, w, h) { kneeAngles.append(a) }
            if let b = PoseMath.angleAt(f0.lm, LM.rightHip, LM.rightKnee, LM.rightAnkle, w, h) { kneeAngles.append(b) }
        }
        if kneeAngles.count >= 12, let kr = Stats.range(kneeAngles) {
            add("膝盖屈伸幅度",
                "\(f(kr.lo))° ~ \(f(kr.hi))°（变化 \(f(kr.span))°）",
                kr.span < 20 ? .warn : .ok,
                kr.span < 20
                ? "膝盖几乎没在动。这一段的弹性大概率该由膝盖给，用腰和脖子代偿既不好看也容易伤腰。"
                : "膝盖在用。盯两点：<b>膝盖尖对着脚尖方向</b>（别内扣），<b>膝盖别超过脚尖太多</b>。")
        }

        // 5) 左右是否对称
        let wl = Stats.pathLength(trail(fr, LM.leftWrist, w, h), maxStep: scale * 1.8)
        let wr = Stats.pathLength(trail(fr, LM.rightWrist, w, h), maxStep: scale * 1.8)
        if wl.n > 6, wr.n > 6, (wl.d > scale * 0.05 || wr.d > scale * 0.05) {
            let big = max(wl.d, wr.d), small = max(1e-3, min(wl.d, wr.d))
            let ratio = big / small
            let which = wl.d > wr.d ? "左" : "右"
            add("左右是否对称",
                ratio > 1.6 ? "\(which)侧动得多（约 \(f(ratio, 1)) 倍）" : "左右接近",
                ratio > 2.4 ? .warn : .ok,
                ratio > 1.6
                ? "这段<b>偏单边</b>，\(which)边是主力。别下意识做成镜像；另一边也不是完全不动，只是幅度小。"
                : "左右差不多，属于对称动作。练的时候可以刻意检查两边幅度是否一致。")
        }

        // 6) 手的高度（相对肩线）
        var wristRel: [CGFloat] = []
        for f0 in fr {
            for (wj, sj) in [(LM.leftWrist, LM.leftShoulder), (LM.rightWrist, LM.rightShoulder)] {
                let p = PoseMath.point(f0.lm, wj, w, h)
                let q = PoseMath.point(f0.lm, sj, w, h)
                guard p.v >= PoseMath.minVisible, q.v >= PoseMath.minVisible else { continue }
                wristRel.append((q.y - p.y) / scale)   // 正值 = 手腕在肩线以上
            }
        }
        if wristRel.count >= 12, let hiRel = wristRel.max() {
            add("手举到多高",
                hiRel > 0 ? "最高超过肩线 \(f(hiRel * 100))% 躯干长" : "最高只到肩下 \(f(-hiRel * 100))% 躯干长",
                hiRel < -0.05 ? .warn : .ok,
                hiRel < -0.05
                ? "整段手都没到肩以上。如果原动作手是举高的，就是<b>幅度没收全</b>——手腕要过肩线才算到位。"
                : "有高位动作。注意<b>手抬高时肩膀别跟着耸</b>，耸肩会让整个动作显得紧。")
        }

        // 7) 有没有离开站立位（breaking 之类）
        if torsoSeen > 10, CGFloat(inverted) / CGFloat(torsoSeen) > 0.12 {
            add("涉及离开站立位",
                "\(f(CGFloat(inverted) / CGFloat(torsoSeen) * 100))% 的时间髋部高于肩部",
                .risk,
                "这段有倒地 / 倒立类动作。<b>先在软垫上、有护具的情况下拆开练</b>，不要直接跟着原速在硬地上做。")
        }

        // 8) 脚步可见率 —— 直接决定「脚步看不看得懂」
        let aL = trail(fr, LM.leftAnkle, w, h).count
        let aR = trail(fr, LM.rightAnkle, w, h).count
        let fL = trail(fr, LM.leftFootIndex, w, h).count
        let fR = trail(fr, LM.rightFootIndex, w, h).count
        let vis = CGFloat(aL + aR + fL + fR) / CGFloat(fr.count * 4)
        add("脚步在画面里看得清吗", "脚部关键点可见率 \(f(vis * 100))%", vis < 0.7 ? .risk : .ok,
            vis < 0.7
            ? "脚下经常被挡住 / 出画。<b>这段的脚步分析不可靠</b>，也不适合用来抠脚步。重拍时把整条腿留在画面里，用 60fps、光线足一点。"
            : "脚下基本都在画面内，素材质量够用来抠脚步。可以用「纯骨架 + 下半身放大 + 脚部轨迹」细看。")

        return (items, "")
    }
}
