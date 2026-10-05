import SwiftUI
import AVFoundation

struct PracticeView: View {
    @ObservedObject var model: StudioModel

    private let speeds: [Float] = [0.25, 0.5, 0.75, 1.0]

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                topBar
                VideoStage(model: model)
                    .frame(height: max(210, geo.size.height * 0.36))
                Divider().overlay(Theme.line)
                ScrollView {
                    VStack(spacing: 12) {
                        transport
                        loopCard
                        CameraPanelView(model: model, tracker: model.camera)
                        DiagnosticsView(items: model.diagItems, note: model.diagNote)
                        displayCard
                        LogCard(lines: model.logLines)
                    }
                    .padding(14)
                }
            }
        }
        .onDisappear { model.stopCamera() }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.sourceName.isEmpty ? "舞蹈片段" : model.sourceName)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
            }
            Spacer()
            Button("换视频") {
                model.stopCamera()
                model.reset()
                model.stage = .empty
            }
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.panel)
            .foregroundStyle(Theme.fg)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var subtitle: String {
        var bits: [String] = []
        if let i = model.info { bits.append(Self.fmt(i.duration)) }
        if model.bpm > 0 { bits.append(String(format: "%.0f BPM", model.bpm)) }
        bits.append(model.beatMode.label)
        if model.segments.count > 0 { bits.append("\(model.segments.count) 段") }
        if model.detectedFrames > 0 { bits.append("骨架 \(model.detectedFrames) 帧") }
        return bits.joined(separator: " · ")
    }

    // MARK: - 播放控制

    private var transport: some View {
        Card(title: "跟着练") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    round("backward.end.fill", "上一拍") { model.jumpBeat(-1) }
                    round("backward.frame.fill", "退一帧") { model.stepFrame(-1) }
                    Button {
                        model.togglePlay()
                    } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 24, weight: .bold))
                            .frame(width: 68, height: 46)
                            .background(Theme.accent)
                            .foregroundStyle(Color.black)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    round("forward.frame.fill", "进一帧") { model.stepFrame(1) }
                    round("forward.end.fill", "下一拍") { model.jumpBeat(1) }
                }

                HStack {
                    Text(Self.fmt(model.currentTime))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                    Text("/ \(Self.fmt(model.abRange.b))")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                    Spacer()
                    Text(model.currentBeatLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }

                HStack(spacing: 8) {
                    Text("速度").font(.system(size: 13)).foregroundStyle(Theme.dim)
                    Picker("速度", selection: Binding(
                        get: { model.speed },
                        set: { model.speed = $0; model.applySpeed() }
                    )) {
                        ForEach(speeds, id: \.self) { s in
                            Text(s == 1.0 ? "原速" : String(format: "%gx", s)).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Toggle(isOn: $model.loopEnabled) {
                    Text("自动循环这一段").font(.system(size: 13))
                }
                .tint(Theme.accent)

                Text("看不懂就按「退一帧」一格一格看，或者把速度降到 0.25x。脚上的动作配合下面的「下半身 · 放大看脚步」。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func round(_ icon: String, _ help: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(Theme.panel)
                .foregroundStyle(Theme.fg)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(help)
    }

    // MARK: - 分段 / 拍子

    private var loopCard: some View {
        Card(title: "分段与拍子") {
            VStack(alignment: .leading, spacing: 12) {
                if model.segments.isEmpty {
                    Text("没有分出段落。可以在下面手动把拍点加倍/减半试试。")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.dim)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(model.segments) { s in
                                Button {
                                    model.selectSegment(s.index)
                                } label: {
                                    VStack(spacing: 2) {
                                        Text("第 \(s.index + 1) 段").font(.system(size: 13, weight: .semibold))
                                        Text("\(Self.fmt(s.start)) - \(Self.fmt(s.end))")
                                            .font(.system(size: 10, design: .monospaced))
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(model.selected == s.index ? Theme.accent : Theme.panel)
                                    .foregroundStyle(model.selected == s.index ? Color.black : Theme.fg)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10)
                                        .stroke(model.selected == s.index ? Color.clear : Theme.line, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }

                    beatChips
                    loopRangeRow

                    HStack(spacing: 8) {
                        smallButton("只循环这一拍") { model.loopOne() }
                        smallButton("循环整段") { model.loopAll() }
                    }
                }

                Divider().overlay(Theme.line)

                HStack(spacing: 8) {
                    Text("节拍不准？").font(.system(size: 12)).foregroundStyle(Theme.dim)
                    smallButton("拍子减半") { model.scaleBeats(by: 0.5) }
                    smallButton("拍子加倍") { model.scaleBeats(by: 2) }
                }
                Text("自动数拍子是猜的，偶尔会数成两倍或一半。点一下就能改，整段的分段会跟着重算。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
            }
        }
    }

    private var beatChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("这一段有 \(model.beatTimesInSegment.count) 拍")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
                Spacer()
                Text("点某一拍设为起点")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(Array(0..<model.beatTimesInSegment.count), id: \.self) { i in
                        let n = i + 1
                        Chip(text: "\(n)",
                             active: n == model.loopStartBeat,
                             inRange: n >= model.loopStartBeat && n <= model.loopEndBeat,
                             strong: ((model.downbeat + i) % 4) == 0) {
                            model.setLoopStart(n)
                        }
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }

    private var loopRangeRow: some View {
        let n = max(1, model.beatTimesInSegment.count)
        let ls = min(model.loopStartBeat, n)
        let le = min(max(model.loopEndBeat, ls), n)
        return HStack(spacing: 10) {
            Text("从第").font(.system(size: 13)).foregroundStyle(Theme.dim)
            stepper(value: ls, range: 1...n) { model.setLoopStart($0) }
            Text("拍 到 第").font(.system(size: 13)).foregroundStyle(Theme.dim)
            stepper(value: le, range: ls...n) { model.setLoopEnd($0) }
            Text("拍").font(.system(size: 13)).foregroundStyle(Theme.dim)
            Spacer()
        }
    }

    private func stepper(value: Int, range: ClosedRange<Int>, set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 0) {
            Button { set(value - 1) } label: {
                Image(systemName: "minus").frame(width: 30, height: 30)
            }
            .disabled(value <= range.lowerBound)
            Text("\(value)")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .frame(minWidth: 26)
            Button { set(value + 1) } label: {
                Image(systemName: "plus").frame(width: 30, height: 30)
            }
            .disabled(value >= range.upperBound)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.fg)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
    }

    private func smallButton(_ t: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(t)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.panel)
                .foregroundStyle(Theme.fg)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 显示设置

    private var displayCard: some View {
        Card(title: "看得更清楚") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("显示", selection: $model.viewMode) {
                    ForEach(StudioModel.ViewMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)

                Picker("放大", selection: $model.focusMode) {
                    ForEach(StudioModel.FocusMode.allCases) { m in
                        Text(m.label).tag(m)
                    }
                }
                .pickerStyle(.segmented)

                Text("放大会自动框住这一段的动作范围，把镜头推近到那块 —— 脚步乱的时候用它。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)

                Toggle(isOn: $model.trailEnabled) {
                    Text("脚部轨迹（左脚蓝、右脚橙）").font(.system(size: 13))
                }
                .tint(Theme.accent)

                Toggle(isOn: $model.clickEnabled) {
                    Text("每拍一声提示音").font(.system(size: 13))
                }
                .tint(Theme.accent)

                Toggle(isOn: $model.mirror) {
                    Text("镜像画面（像照镜子）").font(.system(size: 13))
                }
                .tint(Theme.accent)
            }
        }
    }

    static func fmt(_ s: Double) -> String {
        StudioModel.fmt(s)
    }
}

// MARK: - 视频舞台

struct VideoStage: View {
    @ObservedObject var model: StudioModel

    var body: some View {
        GeometryReader { geo in
            let ar: CGFloat = {
                guard let s = model.info?.displaySize, s.width > 1, s.height > 1 else { return 9.0 / 16.0 }
                return s.width / s.height
            }()
            let box = fitted(ar, in: geo.size)
            let ft = model.focusTransform

            ZStack {
                Color.black
                inner(box)
                    .frame(width: box.width, height: box.height)
                    .scaleEffect(ft.scale, anchor: .topLeading)
                    .offset(x: ft.offset.width * box.width,
                            y: ft.offset.height * box.height)

                VStack {
                    Spacer()
                    HStack {
                        if model.focusMode != .full, ft.scale > 1.02 {
                            tag("放大 \(String(format: "%.1f", ft.scale))x · \(model.focusMode.hint)")
                        }
                        Spacer()
                        if !model.poseOK {
                            tag("⚠️ 没检测到人体骨架")
                        }
                    }
                }
                .padding(8)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .scaleEffect(x: model.mirror ? -1 : 1, y: 1)
        }
        .background(Color.black)
    }

    @ViewBuilder
    private func inner(_ box: CGSize) -> some View {
        ZStack {
            if model.viewMode != .skeleton {
                PlayerLayerView(player: model.player)
            } else {
                Theme.bg
            }
            if model.viewMode != .video, model.poseOK {
                ReferenceOverlay(model: model)
            }
        }
        .frame(width: box.width, height: box.height)
    }

    private func tag(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.bg.opacity(0.8))
            .foregroundStyle(Theme.fg)
            .clipShape(Capsule())
    }

    private func fitted(_ ar: CGFloat, in avail: CGSize) -> CGSize {
        guard avail.width > 1, avail.height > 1, ar > 0 else { return .zero }
        let byW = CGSize(width: avail.width, height: avail.width / ar)
        if byW.height <= avail.height { return byW }
        return CGSize(width: avail.height * ar, height: avail.height)
    }
}
