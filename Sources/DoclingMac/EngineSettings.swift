import SwiftUI

struct EngineSettings: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("引擎与模型").font(.title2.bold())
                Spacer()
                Button("完成") { model.showSettings = false }
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label(model.engineReady ? "解析引擎已就绪" : "需要准备解析引擎", systemImage: model.engineReady ? "checkmark.circle" : "shippingbox")
                        Spacer()
                        Button(model.engineReady ? "修复环境" : "安装") { Task { await model.install() } }.disabled(model.isBusy)
                    }
                    Divider()
                    HStack {
                        Label(model.modelsReady ? "PDF 模型已验证" : "PDF 模型尚未验证", systemImage: model.modelsReady ? "checkmark.circle" : "arrow.down.circle")
                        Spacer()
                        Button(model.modelsReady ? "重新验证" : "下载并验证") { Task { await model.prepareModels() } }
                            .disabled(model.isBusy || !model.engineReady)
                    }
                    Text("仅准备排版与表格模型，复用已有缓存。扫描件使用 Apple OCR。准备完成后，转换进程以离线模式运行。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }
            GroupBox("运行方式") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("单转换进程 · 同批复用模型 · CPU 推理并行度 \(model.configuration?.cpuThreads ?? 0)")
                    Text("队列结束释放模型；关闭窗口可继续处理，退出应用会停止后台任务。")
                    Text("内容缓存：\((model.configuration?.cacheMaxBytes ?? 0) / 1024 / 1024) MB / \(model.configuration?.cacheMaxAgeDays ?? 0) 天。当前队列结果保留到清空队列或退出。")
                }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.upstreamMessage).font(.caption)
                    Link("上游发布说明", destination: URL(string: "https://github.com/docling-project/docling/releases")!).font(.caption)
                }
                Spacer()
                Button("检查上游更新") { Task { await model.checkUpdates() } }.disabled(model.isBusy || !model.engineReady)
            }
            Text("不会后台轮询，也不会自动替换解析环境或模型。依赖更新经过格式回归后随客户端发布。")
                .font(.caption).foregroundStyle(.secondary)
            if model.isBusy {
                HStack { ProgressView().controlSize(.small); Text(model.status).font(.caption); Spacer(); Button("停止") { model.cancel() } }
                ScrollView { Text(model.logs).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(height: 95)
            }
        }.padding(24).frame(width: 520)
    }
}
