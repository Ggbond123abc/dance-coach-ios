import SwiftUI
import AVFoundation
import AVKit

// MARK: - 视频层

final class PlayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerHostView {
        let v = PlayerHostView()
        v.backgroundColor = .black
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        return v
    }

    func updateUIView(_ uiView: PlayerHostView, context: Context) {
        if uiView.playerLayer.player !== player { uiView.playerLayer.player = player }
    }
}

// MARK: - 摄像头预览层

final class PreviewHostView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewHostView {
        let v = PreviewHostView()
        v.backgroundColor = .black
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspect
        if let conn = v.previewLayer.connection {
            if #available(iOS 17.0, *) {
                if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
            } else if conn.isVideoOrientationSupported {
                conn.videoOrientation = .portrait
            }
        }
        return v
    }

    func updateUIView(_ uiView: PreviewHostView, context: Context) {
        if uiView.previewLayer.session !== session { uiView.previewLayer.session = session }
    }
}

// MARK: - 骨架绘制

enum SkeletonDraw {

    static func stroke(_ ctx: inout GraphicsContext, _ lm: [Float], size: CGSize,
                       width: CGFloat, minVis: CGFloat,
                       colorAt: (Int) -> Color?, jointRadius: CGFloat, jointColor: (Int) -> Color?) {
        guard size.width > 1, size.height > 1 else { return }
        let style = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)

        for (a, b) in LM.connections {
            let p = lm.pt(a), q = lm.pt(b)
            guard p.v >= minVis, q.v >= minVis else { continue }
            let c = colorAt(a) ?? colorAt(b) ?? Theme.accent
            var path = Path()
            path.move(to: CGPoint(x: p.x * size.width, y: p.y * size.height))
            path.addLine(to: CGPoint(x: q.x * size.width, y: q.y * size.height))
            ctx.stroke(path, with: .color(c), style: style)
        }

        for i in 0..<LM.count {
            let p = lm.pt(i)
            guard p.v >= minVis else { continue }
            let c = jointColor(i) ?? Theme.accent2
            let r = jointRadius
            let rect = CGRect(x: p.x * size.width - r, y: p.y * size.height - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(c))
        }
    }
}

// MARK: - 参考视频的骨架叠加层

struct ReferenceOverlay: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        Canvas { ctx, size in
            guard size.width > 1, model.poseOK else { return }
            let t = model.currentTime

            if model.trailEnabled, !model.frames.isEmpty {
                drawTrails(&ctx, size: size, now: t)
            }
            guard let f = model.nearestFrame(t) else { return }
            let bold = model.viewMode == .skeleton
            SkeletonDraw.stroke(&ctx, f.lm, size: size,
                                width: max(2, size.width / (bold ? 200 : 260)),
                                minVis: 0.25,
                                colorAt: { _ in Theme.accent },
                                jointRadius: max(1.6, size.width / (bold ? 300 : 380)),
                                jointColor: { _ in Theme.accent2 })
        }
        .allowsHitTesting(false)
    }

    /// 脚部轨迹：左脚蓝、右脚橙，过去 1.4 秒走过的路径
    private func drawTrails(_ ctx: inout GraphicsContext, size: CGSize, now: Double) {
        let window = 1.4
        let from = now - window
        let colors: [Color] = [Theme.accent2, Color(red: 0.941, green: 0.533, blue: 0.243)]

        for side in 0..<2 {
            let ankle = side == 0 ? LM.leftAnkle : LM.rightAnkle
            let toe = side == 0 ? LM.leftFootIndex : LM.rightFootIndex
            var pts: [(t: Double, x: CGFloat, y: CGFloat)] = []
            for f in model.frameRange(from: from, to: now + 0.05) {
                let p = f.lm.pt(ankle)
                let q = f.lm.pt(toe)
                var x: CGFloat
                var y: CGFloat
                if p.v >= 0.3 && q.v >= 0.3 { x = (p.x + q.x) / 2; y = (p.y + q.y) / 2 }
                else if p.v >= 0.3 { x = p.x; y = p.y }
                else { continue }
                pts.append((f.t, x, y))
            }
            guard pts.count >= 2 else { continue }
            for i in 1..<pts.count {
                let age = max(0, min(1, (now - pts[i].t) / window))
                var path = Path()
                path.move(to: CGPoint(x: pts[i - 1].x * size.width, y: pts[i - 1].y * size.height))
                path.addLine(to: CGPoint(x: pts[i].x * size.width, y: pts[i].y * size.height))
                let alpha = 0.75 * (1 - age) + 0.06
                ctx.stroke(path,
                           with: .color(colors[side].opacity(alpha)),
                           style: StrokeStyle(lineWidth: max(1.2, size.width / 300) * (1.3 - age * 0.7),
                                              lineCap: .round))
            }
            if let last = pts.last {
                let r = max(2.5, size.width / 200)
                let rect = CGRect(x: last.x * size.width - r, y: last.y * size.height - r, width: r * 2, height: r * 2)
                ctx.fill(Path(ellipseIn: rect), with: .color(colors[side]))
            }
        }
    }
}
