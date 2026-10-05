import SwiftUI

/// 动作要点 / 易错点。
/// 全部是从骨架里算出来的统计量（速度、起伏、对称性、角度范围…），
/// 不是「识别出了动作名字」—— 所以措辞上说的是「这一段在练什么」。
struct DiagnosticsView: View {
    let items: [DiagItem]
    let note: String

    var body: some View {
        Card(title: "动作要点 · 易错点") {
            if items.isEmpty {
                Text(note.isEmpty ? "先选一个分段。" : note)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.dim)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(items) { it in
                        row(it)
                    }
                    if !note.isEmpty {
                        Text(note).font(.system(size: 11)).foregroundStyle(Theme.dim)
                    }
                }
            }
        }
    }

    private func row(_ it: DiagItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(dot(it.level))
                    .font(.system(size: 13))
                Text(it.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.fg)
                Spacer()
                Text(it.value)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(color(it.level))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(color(it.level).opacity(0.14))
                    .clipShape(Capsule())
            }
            if !it.advice.isEmpty {
                Text(styledAdvice(it.advice))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 21)
            }
        }
        .padding(10)
        .background(Theme.bg.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line.opacity(0.7), lineWidth: 1))
    }

    private func dot(_ l: DiagItem.Level) -> String {
        switch l {
        case .ok: return "🟢"
        case .warn: return "🟡"
        case .risk: return "🔴"
        }
    }

    private func color(_ l: DiagItem.Level) -> Color {
        switch l {
        case .ok: return Theme.accent
        case .warn: return Theme.warn
        case .risk: return Theme.danger
        }
    }
}
