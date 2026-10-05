import SwiftUI

enum Theme {
    static let bg = Color(red: 0.051, green: 0.067, blue: 0.090)
    static let panel = Color(red: 0.086, green: 0.106, blue: 0.133)
    static let panel2 = Color(red: 0.110, green: 0.137, blue: 0.176)
    static let line = Color(red: 0.169, green: 0.204, blue: 0.267)
    static let fg = Color(red: 0.902, green: 0.929, blue: 0.953)
    static let dim = Color(red: 0.545, green: 0.596, blue: 0.663)
    static let accent = Color(red: 0.247, green: 0.725, blue: 0.314)
    static let accent2 = Color(red: 0.184, green: 0.506, blue: 0.969)
    static let warn = Color(red: 0.824, green: 0.600, blue: 0.133)
    static let danger = Color(red: 0.973, green: 0.318, blue: 0.286)
    static let ghost = Color(red: 0.345, green: 0.784, blue: 1.0)
}

struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title).font(.system(size: 15, weight: .semibold))
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
    }
}

struct Chip: View {
    var text: String
    var active: Bool
    var inRange: Bool
    var strong: Bool
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(text)
                .font(.system(size: 13, weight: active ? .bold : .regular, design: .rounded))
                .frame(minWidth: 34)
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background(active ? Theme.accent : Theme.panel)
                .foregroundStyle(active ? Color.black : (inRange ? Theme.accent : Theme.dim))
                .clipShape(Capsule())
                .overlay(
                    Capsule().stroke(inRange ? Theme.accent.opacity(0.7) : Theme.line, lineWidth: 1)
                )
                .overlay(alignment: .bottom) {
                    if strong {
                        Rectangle().fill(Theme.warn).frame(height: 2).padding(.horizontal, 6).offset(y: -1)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}

extension View {
    func panelStyle() -> some View {
        self
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel2)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
    }
}

/// 把带简单标签的文案渲染出来：只处理我们自己的 <b>…</b>
func styledAdvice(_ text: String) -> AttributedString {
    var s = AttributedString()
    var isBold = false
    var buffer = ""
    func flush() {
        guard !buffer.isEmpty else { return }
        var piece = AttributedString(buffer)
        if isBold {
            piece.font = .system(size: 13, weight: .semibold)
            piece.foregroundColor = Theme.fg
        } else {
            piece.font = .system(size: 13)
            piece.foregroundColor = Theme.dim
        }
        s.append(piece)
        buffer = ""
    }
    var i = text.startIndex
    while i < text.endIndex {
        if text[i] == "<", text.index(i, offsetBy: 2, limitedBy: text.endIndex) != nil,
           text[text.index(after: i)] == "b", text[text.index(i, offsetBy: 2)] == ">" {
            flush()
            isBold = true
            i = text.index(i, offsetBy: 3)
        } else if text[i] == "<", text.index(i, offsetBy: 3, limitedBy: text.endIndex) != nil,
                  text[text.index(i, offsetBy: 1)] == "/", text[text.index(i, offsetBy: 2)] == "b",
                  text[text.index(i, offsetBy: 3)] == ">" {
            flush()
            isBold = false
            i = text.index(i, offsetBy: 4)
        } else {
            buffer.append(text[i])
            i = text.index(after: i)
        }
    }
    flush()
    return s
}
