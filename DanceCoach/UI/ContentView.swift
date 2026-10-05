import SwiftUI

struct ContentView: View {
    @StateObject private var model = StudioModel()

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if model.stage == .ready && !model.isAnalyzing {
                PracticeView(model: model)
            } else {
                ImportView(model: model)
            }
        }
        .foregroundStyle(Theme.fg)
    }
}
