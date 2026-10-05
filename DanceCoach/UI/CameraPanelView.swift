import SwiftUI
import AVFoundation

/// 摄像头实时比对。
///
/// 分数只跟「姿势像不像」有关：比对前两边都被摆正、按躯干长归一化，
/// 所以站得远近、身材高矮、手机怎么摆都不影响分数。
/// 「没跟上拍」单独用时间偏移告诉你，不混在分数里。
struct CameraPanelView: View {
    @ObservedObject var model: StudioModel
    @ObservedObject var tracker: CameraTracker

    var body: some View {
        Card(title: "摄像头实时比对") {
            if !model.cameraOn {
                VStack(alignment: .leading, spacing: 10) {
                    Text("把手机架在前面，跟着跳，屏幕上会实时给分，并指出哪个部位最不到位。")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.dim)
                    Text("要全身（连脚）都进画面。前置摄像头，画面是镜像的，跟照镜子一样。")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.dim)
                    Button {
                        model.startCamera()
                    } label: {
                        Label("开启摄像头", systemImage: "camera.viewfinder")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .background(Theme.accent)
                    .foregroundStyle(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    if let e = tracker.errorText {
                        Text(e).font(.system(size: 12)).foregroundStyle(Theme.danger)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        cameraPreview
                        comparison
                    }
                    scoreRow
                    Text(model.cameraHint)
                        .font(.system(size: 13, weight: model.cameraFacingWarn ? .semibold : .regular))
                        .foregroundStyle(model.cameraFacingWarn ? Theme.warn : Theme.fg)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        model.stopCamera()
                    } label: {
                        Text("关掉摄像头（省电）")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .background(Theme.panel)
                    .foregroundStyle(Theme.fg)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
                }
            }
        }
    }

    // MARK: - 自己的画面 + 对比图

    /// 固定尺寸，不靠 SwiftUI 猜：整体照镜子那种感觉最直观
    private var cameraPreview: some View {
        CameraPreviewView(session: tracker.session)
            .frame(width: 150, height: 268)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
            .overlay(alignment: .bottom) {
                Text("你")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Theme.bg.opacity(0.7))
                    .foregroundStyle(Theme.dim)
                    .clipShape(Capsule())
                    .padding(5)
            }
    }

    private var comparison: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                legend(Theme.ghost, "参考")
                legend(Theme.accent, "你（红=差得多）")
            }
            BodyFrameCanvas(user: tracker.latest,
                            refAligned: model.cameraMatch?.refLm,
                            per: model.cameraMatch?.per ?? [:],
                            camSize: tracker.bufferSize)
                .frame(maxWidth: .infinity)
                .frame(height: 246)
                .background(Theme.bg)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
        }
    }

    private var scoreRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let s = model.cameraScore {
                Text("\(s)").font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(PoseMath.scoreColor(s))
                VStack(alignment: .leading, spacing: 1) {
                    Text(rate(s)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.fg)
                    Text("姿势像不像（满分 100）").font(.system(size: 10)).foregroundStyle(Theme.dim)
                }
            } else {
                Text("—").font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.dim)
                Text("等人进画面").font(.system(size: 12)).foregroundStyle(Theme.dim)
            }
            Spacer()
            if let m = model.cameraMatch {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(offsetText(m.offset))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(abs(m.offset) > 0.12 ? Theme.warn : Theme.accent)
                    Text("节奏").font(.system(size: 10)).foregroundStyle(Theme.dim)
                }
            }
        }
    }

    private func rate(_ s: Int) -> String {
        if s >= 88 { return "几乎一样" }
        if s >= 72 { return "挺像" }
        if s >= 55 { return "凑合" }
        if s >= 35 { return "差挺多" }
        return "差很多"
    }

    private func offsetText(_ o: Double) -> String {
        let ms = Int((abs(o) * 1000).rounded())
        if ms < 60 { return "刚好" }
        return o > 0 ? "抢拍 \(ms)ms" : "慢 \(ms)ms"
    }

    private func legend(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(c).frame(width: 8, height: 8)
            Text(t).font(.system(size: 10)).foregroundStyle(Theme.dim)
        }
    }
}

/// 把两套骨架投到同一个「直立、躯干长 = 1、髋部中点 = 原点」的坐标系里。
/// 这样不管摄像头缓冲是横是竖、人站得远还是近，两张骨架都能直接叠在一起看。
struct BodyFrameCanvas: View {
    let user: [Float]?
    let refAligned: [Float]?
    let per: [Int: CGFloat]
    let camSize: CGSize

    var body: some View {
        Canvas { ctx, size in
            guard camSize.width > 1, camSize.height > 1 else { return }
            guard let u = user,
                  let f = PoseMath.frameOf(u, camSize.width, camSize.height) else {
                ctx.draw(Text("等人进画面…")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.dim),
                         at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            let k = size.height * 0.20
            let cx = size.width / 2
            let cy = size.height * 0.70

            func project(_ p: PosePoint) -> CGPoint {
                CGPoint(x: cx + (p.x - f.hip.x) / f.scale * k,
                        y: cy + (p.y - f.hip.y) / f.scale * k)
            }

            // 参考骨架：青色虚线
            if let r = refAligned {
                let style = StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [5, 4])
                for (a, b) in LM.connections {
                    let pa = PoseMath.point(r, a, camSize.width, camSize.height)
                    let pb = PoseMath.point(r, b, camSize.width, camSize.height)
                    guard pa.v >= 0.3, pb.v >= 0.3 else { continue }
                    var path = Path()
                    path.move(to: project(pa))
                    path.addLine(to: project(pb))
                    ctx.stroke(path, with: .color(Theme.ghost), style: style)
                }
                for i in 0..<LM.count {
                    let p = PoseMath.point(r, i, camSize.width, camSize.height)
                    guard p.v >= 0.3 else { continue }
                    let c = project(p)
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)),
                             with: .color(Theme.ghost.opacity(0.85)))
                }
            }

            // 自己：按逐关节误差上色
            let lw = max(3, size.width / 120)
            for (a, b) in LM.connections {
                let pa = PoseMath.point(u, a, camSize.width, camSize.height)
                let pb = PoseMath.point(u, b, camSize.width, camSize.height)
                guard pa.v >= 0.3, pb.v >= 0.3 else { continue }
                var path = Path()
                path.move(to: project(pa))
                path.addLine(to: project(pb))
                let e = [per[a], per[b]].compactMap { $0 }
                let c = e.isEmpty ? Theme.dim : PoseMath.errColor(e.reduce(0, +) / CGFloat(e.count))
                ctx.stroke(path, with: .color(c),
                           style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
            }
            for i in 0..<LM.count {
                let p = PoseMath.point(u, i, camSize.width, camSize.height)
                guard p.v >= 0.3 else { continue }
                let c = project(p)
                let col = per[i].map { PoseMath.errColor($0) } ?? Theme.accent2
                let r = per[i] != nil ? lw * 0.95 : lw * 0.6
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                         with: .color(col))
            }
        }
    }
}
