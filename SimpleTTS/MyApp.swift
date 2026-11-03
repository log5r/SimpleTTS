import Combine
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@main struct MyApp: App {
    @State private var model = ReaderModel()

    var body: some Scene {
        #if os(macOS)
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
        .commands { fileCommands }
        #else
        WindowGroup {
            ContentView(model: model)
                // バックグラウンドで読み上げ中に終了させられた場合（App スイッチャーで上にスワイプしたなど）も位置を保存する
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                    model.prepareForTermination()
                }
        }
        // iPad でハードウェアキーボードの ⌘ 長押しに出るメニュー
        .commands { fileCommands }
        #endif
    }

    private var fileCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("開く…") {
                model.isImporterPresented = true
            }
            .keyboardShortcut("o", modifiers: [.command])
        }
    }
}
