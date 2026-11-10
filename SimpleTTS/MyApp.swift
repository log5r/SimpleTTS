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
                .background(PlaybackKeyForwarder().frame(width: 0, height: 0))
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.prepareForTermination()
                }
        }
        // コンテンツの最小サイズ未満にウィンドウを縮められないようにする
        .windowResizability(.contentMinSize)
        .defaultSize(width: LayoutMetrics.windowDefaultWidth, height: LayoutMetrics.windowDefaultHeight)
        .commands {
            fileCommands
            PlaybackCommands(model: model)
        }
        Settings {
            PrivacySettingsView(model: model)
                .frame(width: 500)
        }
        #else
        WindowGroup {
            ContentView(model: model)
                // バックグラウンドで読み上げ中に終了させられた場合（App スイッチャーで上にスワイプしたなど）も位置を保存する
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                    model.prepareForTermination()
                }
        }
        // iPad でハードウェアキーボードの ⌘ 長押しに出るメニュー
        .commands {
            fileCommands
            PlaybackCommands(model: model)
        }
        #endif
    }

    private var fileCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") {
                model.isImporterPresented = true
            }
            .keyboardShortcut("o", modifiers: [.command])
            .disabled(model.isBusy)
        }
    }
}

/// 「再生」メニュー。読み上げ画面の操作列と同じ操作に、キーボードショートカットを割り当てる。
/// メニューに置くことで、ショートカットを利用者が見つけられ、操作列にフォーカスがなくても使える。
/// 前後の文への移動は修飾キーなしの ←／→ にする（操作列のボタンには従来の ⌘←／⌘→ も残している）。
struct PlaybackCommands: Commands {
    let model: ReaderModel

    var body: some Commands {
        CommandMenu("Playback") {
            Button(model.isPlaying ? LocalizedStringKey("Pause") : LocalizedStringKey("Play")) {
                model.togglePlayback()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!model.canTogglePlayback)

            Divider()

            Button("Previous Sentence") {
                model.step(by: -1)
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(!model.canStepBackward)

            Button("Next Sentence") {
                model.step(by: 1)
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(!model.canStepForward)

            Divider()

            Button("Save Position") {
                model.saveManually()
            }
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(!model.canSaveManually)

            Button("Copy Sentence") {
                model.copyCurrentSentence()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(!model.canCopy)
        }
    }
}

#if os(macOS)
/// スライダーの矢印操作を優先し、読み上げウィンドウ内で Space をメニューに補送する。
private struct PlaybackKeyForwarder: NSViewRepresentable {
    func makeNSView(context: Context) -> KeyView { KeyView() }
    func updateNSView(_ nsView: KeyView, context: Context) {}

    final class KeyView: NSView {
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return handled ? nil : event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard let eventWindow = event.window, eventWindow.isKeyWindow,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    .isDisjoint(with: [.command, .option, .control, .shift])
            else { return false }

            // SwiftUI のスライダーは NSSlider とは限らないため、公開アクセシビリティ API で操作する。
            // ポップオーバー内でも、文移動よりスライダー自身の増減を優先する。
            if let key = event.charactersIgnoringModifiers?.unicodeScalars.first,
               key.value == NSLeftArrowFunctionKey || key.value == NSRightArrowFunctionKey,
               let focused = NSApp.accessibilityFocusedUIElement as AnyObject?,
               focused.accessibilityRole?() == .slider {
                if focused.isAccessibilityEnabled?() != false {
                    if key.value == NSLeftArrowFunctionKey {
                        _ = focused.accessibilityPerformDecrement?()
                    } else {
                        _ = focused.accessibilityPerformIncrement?()
                    }
                }
                // 上限・下限でも矢印を文移動に流さない。
                return true
            }

            guard let window, eventWindow === window,
                  window.attachedSheet == nil, NSApp.modalWindow == nil
            else { return false }

            // 一覧や選択可能な読み取り専用の文は Space を消費してしまうため、メニューに渡す。
            guard event.charactersIgnoringModifiers == " ",
                  ignoresSpace(window.firstResponder),
                  let mainMenu = NSApp.mainMenu
            else { return false }
            return mainMenu.performKeyEquivalent(with: event)
        }

        private func ignoresSpace(_ responder: NSResponder?) -> Bool {
            switch responder {
            case nil, is NSWindow, is NSTableView:
                return true
            case let text as NSText:
                return !text.isEditable
            case is NSControl:
                return false
            case let view as NSView:
                // SwiftUI の textSelection。ボタンのフォーカス用ビューは copy: を持たない。
                return view.responds(to: #selector(NSText.copy(_:)))
            default:
                return false
            }
        }
    }
}
#endif
