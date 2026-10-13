import SwiftUI
import WebKit
import UniformTypeIdentifiers

private let accent = Color(red: 0.12, green: 0.40, blue: 0.35)
// Disambiguate the stable property wrapper from the newer SDK's State macro.
private typealias ViewState<Value> = SwiftUI.State<Value>

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ViewState private var targeted = false
    @ViewState private var previewMode = 0

    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 245, idealWidth: 265, maxWidth: 320)
            VStack(spacing: 0) {
                if let job = model.selected { document(job) } else { welcome }
                Divider()
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .tint(accent)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.chooseFiles() } label: { Label("添加文档", systemImage: "plus") }
                    .help("添加文档 ⌘O")
                Menu {
                    Button("全部导出为 Markdown") { model.exportAll("md") }
                    Button("全部导出为 JSON") { model.exportAll("json") }
                    Button("全部导出为 HTML") { model.exportAll("html") }
                } label: { Label("批量导出", systemImage: "square.and.arrow.up.on.square") }
                .disabled(model.completed == 0 || model.isExporting)
                Button { model.showSettings = true } label: { Label("引擎与模型", systemImage: "gearshape") }
                if model.isBusy {
                    Button { model.cancel() } label: { Label("停止", systemImage: "stop.fill") }
                } else {
                    Button { Task { await model.start() } } label: {
                        Label("开始转换", systemImage: "play.fill")
                    }
                    .disabled(model.isBusy || !model.engineReady || model.waiting == 0)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.add(urls) }; return !urls.isEmpty
        } isTargeted: { targeted = $0 }
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: 12).stroke(accent, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(8).background(accent.opacity(0.08)).allowsHitTesting(false)
            }
        }
        .onChange(of: model.selection) { _, _ in model.loadPreview() }
        .fileImporter(isPresented: $model.importing,
                      allowedContentTypes: AppModel.extensions.compactMap { UTType(filenameExtension: $0) } + [.folder],
                      allowsMultipleSelection: true) { result in
            do { let urls = try result.get(); Task { await model.add(urls) } }
            catch { model.errorMessage = error.localizedDescription }
        }
        .alert("操作未完成", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: { Text(String((model.errorMessage ?? "").suffix(2200))) }
        .sheet(isPresented: $model.showLogs) {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("运行日志").font(.title2.bold()); Spacer(); Button("完成") { model.showLogs = false } }
                Text("最近一次安装或转换的引擎输出。分享前请检查其中的文件路径。").foregroundStyle(.secondary)
                ScrollView {
                    Text(model.logs.isEmpty ? "暂无日志" : model.logs)
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.padding(12).background(.quaternary.opacity(0.5)).clipShape(RoundedRectangle(cornerRadius: 10))
            }.padding(24).frame(width: 720, height: 480)
        }
        .sheet(isPresented: $model.showSettings) { EngineSettings(model: model) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("文档").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(model.jobs.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Menu {
                    Button("清空队列") { model.clearQueue() }.disabled(model.isBusy || model.isImporting || model.isExporting)
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize()
            }.padding(.horizontal, 20).padding(.top, 23).padding(.bottom, 12)
            if model.jobs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("从一份文档开始").font(.system(size: 13, weight: .medium))
                    Text("添加的文件会显示在这里。\n可以拖入多个文档或文件夹。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
                }.padding(20)
                Spacer()
            } else {
                List(selection: $model.selection) {
                    ForEach(model.jobs) { job in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: job.ready ? "doc.text.fill" : "doc")
                                .font(.system(size: 21, weight: .light)).foregroundStyle(job.ready ? accent : .secondary)
                                .frame(width: 24).padding(.top, 3)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(job.source.lastPathComponent).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                HStack(spacing: 5) {
                                    if job.state == .running { ProgressView().controlSize(.mini) }
                                    else { Circle().fill(stateColor(job.state)).frame(width: 5, height: 5) }
                                    Text(job.cached ? "已复用相同内容" : job.state.rawValue).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }
                        }.padding(.vertical, 7).tag(job.id)
                        .contextMenu {
                            Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([job.source]) }
                            Button("从队列移除") { model.remove(job.id) }.disabled(model.isBusy)
                        }
                    }
                }.listStyle(.sidebar)
            }
            Divider().padding(.horizontal, 16)
            VStack(alignment: .leading, spacing: 13) {
                Toggle(isOn: $model.ocr) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("识别扫描件").font(.system(size: 12, weight: .medium))
                        Text("Apple OCR · 中文与英文").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.toggleStyle(.switch).controlSize(.small).disabled(model.isBusy)
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield").font(.system(size: 11))
                    Text("本地处理，无需账号").font(.system(size: 11))
                }.foregroundStyle(.secondary)
            }.padding(20)
            if !model.engineReady { setupCard.padding(.horizontal, 14).padding(.bottom, 16) }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "shippingbox")
                Text(model.installing ? "正在准备引擎" : "首次使用").fontWeight(.semibold)
            }.font(.system(size: 12))
            Text("安装一次解析环境。首次处理 PDF 时还会下载模型，请保持联网。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button { Task { await model.install() } } label: {
                HStack { if model.installing { ProgressView().controlSize(.small) }; Text(model.installing ? "安装中…" : "准备本地引擎") }
                    .frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).disabled(model.isBusy)
            if model.installing { Button("查看安装进度") { model.showLogs = true }.font(.caption).buttonStyle(.plain) }
        }.padding(14).background(accent.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 18).fill(accent.opacity(0.05))
                    .frame(width: 92, height: 112).rotationEffect(.degrees(-12)).offset(x: -15, y: 2)
                RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .textBackgroundColor))
                    .frame(width: 86, height: 108).shadow(color: .black.opacity(0.07), radius: 14, y: 7)
                Image(systemName: "doc.text").font(.system(size: 45, weight: .ultraLight)).foregroundStyle(accent)
                Image(systemName: "arrow.down.right").font(.system(size: 12, weight: .semibold))
                    .padding(9).background(accent).foregroundStyle(.white).clipShape(Circle()).offset(x: 38, y: 40)
            }.frame(height: 135)
            Text("让文档，回到内容本身。").font(.system(size: 27, weight: .semibold)).padding(.top, 22)
            Text("把 PDF、Office 文档或图片拖到这里，\n转成清晰、有结构、可继续使用的文本。")
                .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(6)
                .multilineTextAlignment(.center).padding(.top, 14)
            Button { model.chooseFiles() } label: {
                Label("选择文档", systemImage: "plus").padding(.horizontal, 16).padding(.vertical, 6)
            }.buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 27)
            Text("或直接拖放文件 · ⌘O").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 12)
            HStack(spacing: 9) {
                ForEach(["PDF", "DOCX", "PPTX", "XLSX", "图片"], id: \.self) { item in
                    Text(item).font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 5)
                        .overlay(Capsule().stroke(.quaternary))
                }
            }.padding(.top, 38)
            Spacer()
            Text("POWERED BY DOCLING").font(.system(size: 8, weight: .medium, design: .monospaced))
                .tracking(2).foregroundStyle(.tertiary).padding(.bottom, 25)
        }.frame(maxWidth: .infinity)
    }

    @ViewBuilder private func document(_ job: DocumentJob) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(job.source.lastPathComponent).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    Text(job.ready ? "\(job.pages > 0 ? "\(job.pages) 页 · " : "")\(String(format: "%.1f", job.seconds)) 秒 · \(job.cached ? "复用缓存" : "本地转换")" : job.state.rawValue)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if job.ready {
                    Button { model.copyMarkdown() } label: { Image(systemName: "doc.on.doc") }.help("复制 Markdown")
                    Menu {
                        Button("Markdown (.md)") { model.export("md") }
                        Button("Docling JSON (.json)") { model.export("json") }
                        Button("HTML (.html)") { model.export("html") }
                    } label: { Label("导出", systemImage: "square.and.arrow.up") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .disabled(model.isExporting)
                }
            }.padding(24)
            Divider()
            if job.ready {
                if job.state == .partial {
                    Label("部分内容未能解析，请核对结果后导出。", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).padding(10)
                    if !job.message.isEmpty { Text(job.message).font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
                }
                HStack {
                    Picker("显示方式", selection: $previewMode) {
                        Text("预览").tag(0); Text("Markdown").tag(1)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 180)
                    Spacer()
                    Text("图片嵌入导出文件").font(.system(size: 10)).foregroundStyle(.tertiary)
                }.padding(.horizontal, 24).padding(.vertical, 12)
                if model.previewLimited {
                    Text("大文档显示有限预览；复制与导出保留完整内容。")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 8)
                }
                if previewMode == 0 && !model.html.isEmpty {
                    DocumentPreview(html: model.html) { urls in Task { await model.add(urls) } }
                }
                else {
                    ScrollView([.vertical, .horizontal]) {
                        Text(model.markdown).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading).padding(24)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Spacer()
                if job.state == .running {
                    ProgressView().controlSize(.large)
                    Text("正在整理文档结构").font(.title3).padding(.top, 16)
                    Text("\(model.status)").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                    Button("查看运行日志") { model.showLogs = true }.buttonStyle(.link).padding(.top, 12)
                } else if job.state == .failed || job.state == .cancelled {
                    Image(systemName: job.state == .failed ? "exclamationmark.circle" : "stop.circle")
                        .font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
                    Text(job.state.rawValue).font(.title3).padding(.top, 12)
                    if !job.message.isEmpty {
                        ScrollView { Text(job.message).font(.caption).textSelection(.enabled).foregroundStyle(.secondary) }
                            .frame(maxWidth: 480, maxHeight: 110).padding(.top, 8)
                    }
                    Button("重新加入队列") { model.retry(job.id) }.disabled(model.isBusy).padding(.top, 16)
                } else {
                    Image(systemName: "doc.text.magnifyingglass").font(.system(size: 38, weight: .ultraLight)).foregroundStyle(accent)
                    Text("准备好，提取这份文档。").font(.title3).padding(.top, 16)
                    Text("保留标题、段落、列表与表格结构").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                    Button("开始转换") { Task { await model.start() } }
                        .buttonStyle(.borderedProminent).disabled(!model.engineReady || model.isBusy).padding(.top, 22)
                }
                Spacer()
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 7) {
            if model.isBusy || model.isImporting || model.isExporting { ProgressView().controlSize(.mini) }
            else { Circle().fill(model.engineReady ? accent : .secondary).frame(width: 5, height: 5) }
            Text(model.isImporting ? "正在后台整理文件…" : model.isExporting ? "正在后台导出…" : model.status).lineLimit(1)
            Spacer()
            if model.waiting > 0 { Text("\(model.waiting) 份待处理").foregroundStyle(.secondary) }
            Button { model.showLogs = true } label: { Image(systemName: "terminal") }.buttonStyle(.plain).help("运行日志")
        }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 18).frame(height: 34)
    }

    private func stateColor(_ state: JobState) -> Color {
        switch state {
        case .done: return accent
        case .failed, .partial: return .orange
        default: return .secondary.opacity(0.5)
        }
    }
}

struct DocumentPreview: NSViewRepresentable {
    let html: String
    let onFileDrop: ([URL]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> FileDropWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let view = FileDropWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.onFileDrop = onFileDrop
        return view
    }

    func updateNSView(_ view: FileDropWebView, context: Context) {
        view.onFileDrop = onFileDrop
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html
        let style = """
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <style>:root{color-scheme:light dark}body{font:14px/1.85 -apple-system,BlinkMacSystemFont,sans-serif!important;max-width:780px!important;margin:0 auto!important;padding:24px 36px!important;background:transparent!important;color:light-dark(#303732,#e2e6e3)!important}h1,h2,h3{line-height:1.35}h1{font-size:25px}h2{font-size:20px;margin-top:30px}table{border-collapse:collapse;width:100%;font-size:12px}th,td{border:1px solid #8884;padding:9px 12px;text-align:left}th{background:#8881}img{max-width:100%;height:auto}pre{white-space:pre-wrap;background:#8881;padding:16px;border-radius:8px}a{color:#328875}figure{margin:16px 0}</style>
        """
        // Put CSP before any document resource so preview cannot fetch remote content.
        view.loadHTMLString(style + html, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String?
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.navigationType == .other && action.request.url?.scheme == "about" ? .allow : .cancel)
        }
    }
}
