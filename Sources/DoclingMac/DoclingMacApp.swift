import AppKit
import SwiftUI

@main
struct DoclingMacApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Docling Mac", id: "main") {
            ContentView(model: model)
                .environment(\.locale, L10n.locale)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear { delegate.model = model }
                .onOpenURL { url in Task { await model.add([url]) } }
        }
        .defaultSize(width: 1080, height: 730)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.text("添加文档…")) { model.chooseFiles() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .appSettings) {
                Button(L10n.text("设置…")) { model.showSettings = true }.keyboardShortcut(",")
            }
            CommandGroup(replacing: .help) {
                Link(L10n.text("Docling 项目"), destination: URL(string: "https://github.com/docling-project/docling")!)
                Link(L10n.text("安装 uv"), destination: URL(string: "https://docs.astral.sh/uv/getting-started/installation/")!)
                Button(L10n.text("查看运行日志")) { model.showLogs = true }
                Button(L10n.text("引擎与模型…")) { model.showSettings = true }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    private var terminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        guard let model else { return .terminateNow }
        terminating = true
        Task {
            let saved = await model.shutdown()
            if !saved { terminating = false }
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }
}
