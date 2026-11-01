import AppKit
import Combine
import SwiftUI

@main struct MyApp: App {
    @State private var model = ReaderModel()

    var body: some Scene {
        // 状態を 1 つのモデルで持つため、複数ウィンドウを作らない Window にしている
        Window("SimpleTTS", id: "main") {
            ContentView(model: model)
                .frame(minWidth: LayoutMetrics.windowMinWidth, minHeight: LayoutMetrics.windowMinHeight)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.prepareForTermination()
                }
        }
        // コンテンツの最小サイズ未満にウィンドウを縮められないようにする
        .windowResizability(.contentMinSize)
        .defaultSize(width: LayoutMetrics.windowDefaultWidth, height: LayoutMetrics.windowDefaultHeight)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("開く…") {
                    model.isImporterPresented = true
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
        }
    }
}
