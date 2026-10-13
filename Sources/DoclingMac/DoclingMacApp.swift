import AppKit
import SwiftUI

@main
struct DoclingMacApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Docling Mac", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear { delegate.model = model }
                .onOpenURL { url in Task { await model.add([url]) } }
        }
        .defaultSize(width: 1080, height: 730)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("添加文档…") { model.chooseFiles() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .help) {
                Link("Docling 项目", destination: URL(string: "https://github.com/docling-project/docling")!)
                Link("安装 uv", destination: URL(string: "https://docs.astral.sh/uv/getting-started/installation/")!)
                Button("查看运行日志") { model.showLogs = true }
                Button("引擎与模型…") { model.showSettings = true }
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
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
