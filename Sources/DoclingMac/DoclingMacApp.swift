import AppKit
import SwiftUI

@main
struct DoclingMacApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Docling Mac", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 600)
                .onOpenURL { model.add([$0]) }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.cleanup() }
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
            }
        }
    }
}
