import SwiftUI

struct EngineSettings: View {
    @ObservedObject var model: AppModel
    @AppStorage(AppLanguage.preferenceKey) private var language = AppLanguage.system.rawValue
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(L10n.text("引擎与模型")).font(.title2.bold())
                Spacer()
                Button(L10n.text("完成")) { model.showSettings = false }
                    .modifier(AppActionStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
            GroupBox(L10n.text("语言")) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker(L10n.text("语言"), selection: $language) {
                        Text(L10n.text("跟随系统")).tag(AppLanguage.system.rawValue)
                        Text("English").tag(AppLanguage.english.rawValue)
                        Text("简体中文").tag(AppLanguage.simplifiedChinese.rawValue)
                    }
                    .onChange(of: language) { _, value in
                        if let choice = AppLanguage(rawValue: value) { AppLanguage.save(choice) }
                    }
                    Text(L10n.text("重新打开应用后生效。请先等待当前任务完成，再退出并重新打开。"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(8)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label(model.engineReady ? L10n.text("解析引擎已就绪") : L10n.text("需要准备解析引擎"), systemImage: model.engineReady ? "checkmark.circle" : "shippingbox")
                        Spacer()
                        Button(model.engineReady ? L10n.text("修复环境") : L10n.text("安装")) { Task { await model.install() } }.disabled(model.isBusy)
                    }
                    Divider()
                    HStack {
                        Label(model.modelsReady ? L10n.text("PDF 模型已验证") : L10n.text("PDF 模型尚未验证"), systemImage: model.modelsReady ? "checkmark.circle" : "arrow.down.circle")
                        Spacer()
                        Button(model.modelsReady ? L10n.text("重新验证") : L10n.text("下载并验证")) { Task { await model.prepareModels() } }
                            .disabled(model.isBusy || !model.engineReady)
                    }
                    Text(L10n.text("仅准备排版与表格模型，复用已有缓存。扫描件使用 Apple OCR。准备完成后，转换进程以离线模式运行。"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(8)
            }
            GroupBox(L10n.text("运行方式")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("单转换进程 · 同批复用模型 · CPU 推理并行度 %@", String(describing: model.configuration?.cpuThreads ?? 0)))
                    Text(L10n.text("队列结束释放模型；关闭窗口可继续处理，退出应用会停止后台任务。"))
                    Text(L10n.text("内容缓存：%@ MB / %@ 天。当前队列结果保留到清空队列或退出。", String(describing: (model.configuration?.cacheMaxBytes ?? 0) / 1024 / 1024), String(describing: model.configuration?.cacheMaxAgeDays ?? 0)))
                }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.upstreamMessage).font(.caption)
                    Link(L10n.text("上游发布说明"), destination: URL(string: "https://github.com/docling-project/docling/releases")!).font(.caption)
                }
                Spacer()
                Button(L10n.text("检查上游更新")) { Task { await model.checkUpdates() } }.disabled(model.isBusy || !model.engineReady)
            }
            Text(L10n.text("不会后台轮询，也不会自动替换解析环境或模型。依赖更新经过格式回归后随客户端发布。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.isBusy {
                HStack { ProgressView().controlSize(.small); Text(model.status).font(.caption); Spacer(); Button(L10n.text("停止")) { model.cancel() } }
                ScrollView { Text(model.logs).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 95)
            }
        }.padding(24).frame(width: 620).tint(AppAppearance.accent)
    }
}
