import SwiftUI
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers

/// 从相册把视频拷进 App 自己的临时目录。
/// PHPicker 不需要相册权限（系统替你选，App 只拿到你挑中的那一个文件）。
struct VideoTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { item in
            SentTransferredFile(item.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dst = FileManager.default.temporaryDirectory
                .appendingPathComponent("dancecoach-\(UUID().uuidString).\(ext)")
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: received.file, to: dst)
            return VideoTransferable(url: dst)
        }
    }
}

struct ImportView: View {
    @ObservedObject var model: StudioModel

    @State private var pick: PhotosPickerItem?
    @State private var busy = false
    @State private var link = ""
    @State private var msg: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if model.isAnalyzing {
                    analyzing
                } else {
                    pickerCard
                    linkCard
                    tipsCard
                }
                if let e = model.errorText {
                    Text("❌ \(e)")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.danger)
                        .panelStyle()
                }
                if !model.logLines.isEmpty { LogCard(lines: model.logLines) }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: pick) { item in
            guard let item else { return }
            Task { await loadFromPhotos(item) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("街舞拆解").font(.system(size: 30, weight: .heavy))
            Text("丢一个舞蹈视频进来，帮你拆动作、数拍子、指易错点。全部计算都在手机上完成，不联网也能用。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.dim)
        }
        .padding(.top, 8)
    }

    private var pickerCard: some View {
        Card(title: "① 选视频") {
            PhotosPicker(selection: $pick, matching: .videos) {
                HStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled")
                    Text(busy ? "正在读取…" : "从相册选一个舞蹈视频")
                        .fontWeight(.semibold)
                    Spacer()
                    if busy { ProgressView().tint(Theme.fg) }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.accent)
                .foregroundStyle(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(busy)
            Text("建议：一段只放一个动作/一个小组合，10~60 秒最好，人物全身都在画面里，镜头别晃。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.dim)
        }
    }

    private var linkCard: some View {
        Card(title: "② 或者贴一个视频直链") {
            HStack(spacing: 8) {
                TextField("https://…/dance.mp4", text: $link)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .padding(10)
                    .background(Theme.bg)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
                Button {
                    download()
                } label: {
                    Text("下载").fontWeight(.semibold).padding(.horizontal, 14).padding(.vertical, 10)
                }
                .background(Theme.panel2)
                .foregroundStyle(Theme.fg)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
            }
            Text("只支持「直接指向视频文件」的链接（.mp4 / .mov）。抖音、B站那种网页链接不行——先存到相册再走①。")
                .font(.system(size: 12))
                .foregroundStyle(Theme.dim)
            if let msg {
                Text(msg).font(.system(size: 12)).foregroundStyle(msg.hasPrefix("❌") ? Theme.danger : Theme.warn)
            }
        }
    }

    private var tipsCard: some View {
        Card(title: "点「开始分析」之后会发生什么") {
            VStack(alignment: .leading, spacing: 8) {
                tip("1", "逐帧提取你的骨架（Vision，本机跑）")
                tip("2", "听音乐，数出 BPM 和每一个拍点")
                tip("3", "按 8 拍切成小段，每段单独循环")
                tip("4", "算出这段在练什么、哪里最容易做错")
                tip("5", "可选：开摄像头，跟着跳，实时打分")
                Text("分析期间别切走 App —— iOS 会把后台的画面处理停掉。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warn)
                    .padding(.top, 2)
            }
        }
    }

    private func tip(_ n: String, _ s: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(n)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Color.black)
                .frame(width: 18, height: 18)
                .background(Theme.accent)
                .clipShape(Circle())
            Text(s).font(.system(size: 13)).foregroundStyle(Theme.fg)
        }
    }

    private var analyzing: some View {
        Card(title: "正在分析") {
            VStack(alignment: .leading, spacing: 12) {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
                Text("\(Int(model.progress * 100))%")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("别切走 App、别锁屏。1 分钟的视频大约要等 20~60 秒，取决于机型。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
                if !model.logLines.isEmpty {
                    Divider().overlay(Theme.line)
                    LogCard(lines: model.logLines, bare: true)
                }
            }
        }
    }

    @MainActor
    private func loadFromPhotos(_ item: PhotosPickerItem) async {
        busy = true
        defer { busy = false }
        do {
            guard let t = try await item.loadTransferable(type: VideoTransferable.self) else {
                msg = "❌ 读不出这个视频，换一个试试。"
                return
            }
            model.load(url: t.url, name: "相册视频")
            model.analyze()
        } catch {
            msg = "❌ 读取失败：\(error.localizedDescription)"
        }
    }

    private func download() {
        let s = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            msg = "❌ 链接格式不对，要以 http:// 或 https:// 开头。"
            return
        }
        busy = true
        msg = "正在下载…"
        URLSession.shared.downloadTask(with: u) { tmp, resp, err in
            DispatchQueue.main.async {
                busy = false
                guard let tmp, err == nil else {
                    msg = "❌ 下载失败：\(err?.localizedDescription ?? "未知错误")"
                    return
                }
                if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 400 {
                    msg = "❌ 服务器返回 \(code)，这个链接大概不是视频文件。"
                    return
                }
                let ext = u.pathExtension.isEmpty ? "mp4" : u.pathExtension
                let dst = FileManager.default.temporaryDirectory
                    .appendingPathComponent("dancecoach-\(UUID().uuidString).\(ext)")
                do {
                    try FileManager.default.moveItem(at: tmp, to: dst)
                } catch {
                    msg = "❌ 保存失败。"
                    return
                }
                msg = nil
                model.load(url: dst, name: u.lastPathComponent)
                model.analyze()
            }
        }.resume()
    }
}

struct LogCard: View {
    let lines: [String]
    var bare = false

    var body: some View {
        let scroll = ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines.enumerated()), id: \.offset) { pair in
                    Text(pair.element)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 150)

        return Group {
            if bare { scroll } else { Card(title: "日志") { scroll } }
        }
    }
}
