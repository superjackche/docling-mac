import SwiftUI
import WebKit
import UniformTypeIdentifiers

private let accent = AppAppearance.accent
// Disambiguate the stable property wrapper from the newer SDK's State macro.
private typealias ViewState<Value> = SwiftUI.State<Value>

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ViewState private var targeted = false
    @ViewState private var previewTargeted = false
    private var dropTargeted: Bool { targeted || previewTargeted }

    var body: some View {
        NavigationSplitView {
            sidebar.frame(minHeight: 0, maxHeight: .infinity)
                .navigationSplitViewColumnWidth(min: 245, ideal: 265, max: 320)
        } detail: {
            VStack(spacing: 0) {
                if let job = model.selected { document(job) } else { welcome }
                Divider()
                footer
            }
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .tint(accent)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.chooseFiles() } label: { Label(L10n.text("添加文档"), systemImage: "plus") }
                    .help(L10n.text("添加文档 ⌘O"))
                Button { model.openResults() } label: { Label(L10n.text("结果文件夹"), systemImage: "folder") }
                    .help(L10n.text("打开 ~/Docling_Mac，转换结果自动保存于此"))
            }
            if #available(macOS 26, *) { ToolbarSpacer(.fixed, placement: .primaryAction) }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.showSettings = true } label: { Label(L10n.text("引擎与模型"), systemImage: "gearshape") }
                if model.isBusy {
                    Button { model.cancel() } label: { Label(L10n.text("停止"), systemImage: "stop.fill") }
                } else if model.waiting > 0 && model.queuePaused {
                    Button { Task { await model.start() } } label: {
                        Label(L10n.text("继续处理"), systemImage: "play.fill")
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
            if dropTargeted {
                ZStack {
                    accent.opacity(0.12)
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(accent, style: StrokeStyle(lineWidth: 3, dash: [10, 6])).padding(10)
                    VStack(spacing: 14) {
                        Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 44, weight: .light)).foregroundStyle(accent)
                        Text(L10n.text("松开以添加文档")).font(.system(size: 25, weight: .semibold))
                        Text(model.queuePaused ? L10n.text("加入暂停队列 · 继续后自动处理") : L10n.text("多个文件或文件夹 · 放下即开始转换"))
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.primary).padding(.horizontal, 36).padding(.vertical, 30)
                    .modifier(DropFeedbackStyle())
                }.allowsHitTesting(false)
            }
        }
        .onChange(of: model.selection) { _, _ in model.loadPreview() }
        .onChange(of: model.previewMode) { _, _ in model.loadPreview() }
        .fileImporter(isPresented: $model.importing,
                      allowedContentTypes: AppModel.extensions.compactMap { UTType(filenameExtension: $0) } + [.folder],
                      allowsMultipleSelection: true) { result in
            do { let urls = try result.get(); Task { await model.add(urls) } }
            catch { model.errorMessage = error.localizedDescription }
        }
        .alert(L10n.text("操作未完成"), isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button(L10n.text("好"), role: .cancel) { model.errorMessage = nil }
        } message: { Text(String((model.errorMessage ?? "").suffix(2200))) }
        .sheet(isPresented: $model.showLogs) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(L10n.text("运行日志")).font(.title2.bold())
                    Spacer()
                    Button(L10n.text("完成")) { model.showLogs = false }
                        .modifier(AppActionStyle(prominent: true)).keyboardShortcut(.defaultAction)
                }
                Text(L10n.text("最近一次安装或转换的引擎输出。分享前请检查其中的文件路径。")).foregroundStyle(.secondary)
                ScrollView {
                    Text(model.logs.isEmpty ? L10n.text("暂无日志") : model.logs)
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
                Text(L10n.text("文档")).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(model.jobs.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Menu {
                    Button(L10n.text("清空队列")) { model.clearQueue() }.disabled(model.isBusy || model.isImporting || model.isSaving)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel(L10n.text("队列操作"))
            }.padding(.horizontal, 20).padding(.top, 23).padding(.bottom, 12)
            Button { model.chooseFiles() } label: {
                VStack(spacing: 5) {
                    Label(L10n.text("拖入文件或文件夹"), systemImage: "tray.and.arrow.down")
                        .font(.system(size: 12, weight: .medium))
                    Text(L10n.text("列表、预览和空白处均可放下")).font(.system(size: 10)).foregroundStyle(Color.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(accent.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(accent.opacity(0.3), style: StrokeStyle(dash: [4, 4])))
            }.buttonStyle(.plain).foregroundStyle(accent).padding(.horizontal, 14).padding(.bottom, 8)
            if model.jobs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("从一份文档开始")).font(.system(size: 13, weight: .medium))
                    Text(L10n.text("添加的文件会显示在这里。\n可以拖入多个文档或文件夹。"))
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
                                    if job.state == .running || job.saving { ProgressView().controlSize(.mini) }
                                    else { Circle().fill(stateColor(job.state)).frame(width: 5, height: 5) }
                                    Text(jobStatus(job))
                                        .font(.system(size: 10))
                                        .foregroundStyle(model.showsReuseNotice(job.id) ? accent : .secondary)
                                }
                            }
                        }.padding(.vertical, 7).tag(job.id)
                        .contextMenu {
                            Button(L10n.text("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([job.source]) }
                            Button(L10n.text("从队列移除")) { model.remove(job.id) }.disabled(model.isBusy || model.isSaving)
                        }
                    }
                }.listStyle(.sidebar).scrollContentBackground(.hidden)
            }
            Divider().padding(.horizontal, 16)
            VStack(alignment: .leading, spacing: 13) {
                Toggle(isOn: $model.ocr) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.text("识别扫描件")).font(.system(size: 12, weight: .medium))
                        Text(L10n.text("Apple OCR · 中文与英文")).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.toggleStyle(.switch).controlSize(.small).disabled(model.isBusy)
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield").font(.system(size: 11))
                    Text(L10n.text("本地处理，无需账号")).font(.system(size: 11))
                }.foregroundStyle(.secondary)
            }.padding(20)
            if !model.engineReady { setupCard.padding(.horizontal, 14).padding(.bottom, 16) }
        }
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "shippingbox")
                Text(model.installing ? L10n.text("正在准备引擎") : L10n.text("首次使用")).fontWeight(.semibold)
            }.font(.system(size: 12))
            Text(L10n.text("安装一次解析环境。首次处理 PDF 时还会下载模型，请保持联网。"))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button { Task { await model.install() } } label: {
                HStack { if model.installing { ProgressView().controlSize(.small) }; Text(model.installing ? L10n.text("安装中…") : L10n.text("准备本地引擎")) }
                    .frame(maxWidth: .infinity)
            }.modifier(AppActionStyle(prominent: true)).disabled(model.isBusy)
            if model.installing { Button(L10n.text("查看安装进度")) { model.showLogs = true }.font(.caption).buttonStyle(.plain) }
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
            Text(L10n.text("拖入文件或文件夹")).font(.system(size: 27, weight: .semibold)).padding(.top, 22)
            Text(L10n.text("放下后自动转换，无需再点开始。\n结果自动保存到 ~/Docling_Mac。"))
                .font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(6)
                .multilineTextAlignment(.center).padding(.top, 14)
            Button { model.chooseFiles() } label: {
                Label(L10n.text("选择文档"), systemImage: "plus").padding(.horizontal, 16).padding(.vertical, 6)
            }.modifier(AppActionStyle(prominent: true)).controlSize(.large).padding(.top, 27)
            Text(L10n.text("整个内容区均可拖入 · ⌘O 批量选择")).font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 12)
            HStack(spacing: 9) {
                ForEach(["PDF", "DOCX", "PPTX", "XLSX", L10n.text("图片")], id: \.self) { item in
                    Text(item).font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 5)
                        .overlay(Capsule().stroke(.quaternary))
                }
            }.padding(.top, 38)
            Spacer()
            Text("POWERED BY DOCLING").font(.system(size: 8, weight: .medium, design: .monospaced))
                .tracking(2).foregroundStyle(.tertiary).padding(.bottom, 25)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 20)
                .stroke(accent.opacity(0.22), style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
                .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 48).allowsHitTesting(false))
    }

    @ViewBuilder private func document(_ job: DocumentJob) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(job.source.lastPathComponent).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    Text(job.ready ? L10n.text("%@%@ 秒 · %@", String(describing: job.pages > 0 ? L10n.text("%@ 页 · ", String(job.pages)) : ""), String(describing: String(format: "%.1f", job.seconds)), jobStatus(job)) : L10n.text(job.state.rawValue))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if job.ready {
                    GlassActions {
                        HStack(spacing: 8) {
                            Button { model.copyMarkdown() } label: { Image(systemName: "doc.on.doc") }
                                .help(L10n.text("复制 Markdown")).accessibilityLabel(L10n.text("复制 Markdown"))
                            Button { model.openResults(job.savedOutput) } label: {
                                Label(L10n.text("打开结果"), systemImage: "folder")
                            }.disabled(job.savedOutput == nil)
                        }.modifier(AppActionStyle())
                    }
                }
            }.padding(24)
            Divider()
            if job.ready {
                if job.state == .partial {
                    Label(L10n.text("部分内容未能解析，请核对可用结果。"), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange).padding(10)
                    if !job.message.isEmpty { Text(job.message).font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
                }
                if let error = job.saveError {
                    HStack {
                        Text(L10n.text("自动保存失败：") + error).font(.caption).textSelection(.enabled)
                        Button(L10n.text("重试保存")) { model.saveResult(job.id) }.modifier(AppActionStyle())
                    }.foregroundStyle(.orange).padding(12)
                }
                HStack {
                    Picker(L10n.text("显示方式"), selection: $model.previewMode) {
                        Text(L10n.text("预览")).tag(0); Text("Markdown").tag(1)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 180)
                    Spacer()
                    Text(job.saving ? L10n.text("正在自动保存…") : job.savedOutput != nil ? L10n.text("已自动保存 · 图片已嵌入") : L10n.text("转换结果待保存")).font(.system(size: 10)).foregroundStyle(.tertiary)
                }.padding(.horizontal, 24).padding(.vertical, 12)
                if model.previewLimited {
                    Text(L10n.text("超过 100 MB 的格式显示有限文本预览；结果文件保留完整内容。"))
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 8)
                }
                if model.previewLoading {
                    ProgressView(L10n.text("正在载入预览…")).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.previewMode == 0 && !model.html.isEmpty {
                    DocumentPreview(html: model.html,
                                    onFileDrop: { urls in Task { await model.add(urls) } },
                                    onTargetChanged: { previewTargeted = $0 })
                        .onDisappear { previewTargeted = false }
                }
                else {
                    MarkdownPreview(text: model.markdown)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Spacer()
                if job.state == .running {
                    ProgressView().controlSize(.large)
                    Text(L10n.text("正在整理文档结构")).font(.title3).padding(.top, 16)
                    Text("\(model.status)").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                    Button(L10n.text("查看运行日志")) { model.showLogs = true }.buttonStyle(.link).padding(.top, 12)
                } else if job.state == .failed || job.state == .cancelled {
                    Image(systemName: job.state == .failed ? "exclamationmark.circle" : "stop.circle")
                        .font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
                    Text(L10n.text(job.state.rawValue)).font(.title3).padding(.top, 12)
                    if !job.message.isEmpty {
                        ScrollView { Text(job.message).font(.caption).textSelection(.enabled).foregroundStyle(.secondary) }
                            .frame(maxWidth: 480, maxHeight: 110).padding(.top, 8)
                    }
                    Button(L10n.text("重试转换")) { model.retry(job.id) }
                        .modifier(AppActionStyle(prominent: true)).disabled(model.isBusy).padding(.top, 16)
                } else {
                    Image(systemName: "doc.text.magnifyingglass").font(.system(size: 38, weight: .ultraLight)).foregroundStyle(accent)
                    Text(model.queuePaused ? L10n.text("队列已暂停") : model.engineReady ? L10n.text("已排队，将自动开始转换") : L10n.text("准备本地引擎后自动转换"))
                        .font(.title3).padding(.top, 16)
                    Text(L10n.text("保留标题、段落、列表与表格结构")).font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                    if !model.engineReady {
                        Button(L10n.text("准备本地引擎")) { Task { await model.install() } }
                            .modifier(AppActionStyle(prominent: true)).disabled(model.isBusy).padding(.top, 22)
                    } else if model.queuePaused {
                        Button(L10n.text("继续处理")) { Task { await model.start() } }
                            .modifier(AppActionStyle(prominent: true)).disabled(model.isBusy).padding(.top, 22)
                    }
                }
                Spacer()
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 7) {
            if model.isBusy || model.isImporting || model.isSaving { ProgressView().controlSize(.mini) }
            else { Circle().fill(model.engineReady ? accent : .secondary).frame(width: 5, height: 5) }
            Text(model.isImporting ? L10n.text("正在后台整理文件…") : model.isSaving ? L10n.text("正在自动保存结果…") : model.status).lineLimit(1)
            Spacer()
            if model.waiting > 0 { Text(L10n.text("%@ 份待处理", String(describing: model.waiting))).foregroundStyle(.secondary) }
            Button { model.showLogs = true } label: { Image(systemName: "terminal") }
                .buttonStyle(.plain).help(L10n.text("运行日志")).accessibilityLabel(L10n.text("运行日志"))
        }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 18).frame(height: 34)
    }

    private func jobStatus(_ job: DocumentJob) -> String {
        if job.saveError != nil { return L10n.text("保存失败") }
        if job.saving { return L10n.text("正在保存") }
        if model.showsReuseNotice(job.id) { return L10n.text("已复用") }
        return L10n.text(job.state.rawValue)
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
    let onTargetChanged: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> FileDropWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let view = FileDropWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.onFileDrop = onFileDrop
        view.onTargetChanged = onTargetChanged
        return view
    }

    func updateNSView(_ view: FileDropWebView, context: Context) {
        view.onFileDrop = onFileDrop
        view.onTargetChanged = onTargetChanged
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

struct MarkdownPreview: NSViewRepresentable {
    let text: String
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        let view = NSTextView(frame: scroll.bounds)
        view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textContainerInset = NSSize(width: 24, height: 24)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.containerSize = view.maxSize
        view.textContainer?.widthTracksTextView = false
        view.layoutManager?.allowsNonContiguousLayout = true
        // Leave Finder file drops to the full-window SwiftUI destination.
        view.unregisterDraggedTypes()
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.lastText != text, let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.lastText = text
        view.string = text
        view.scrollToBeginningOfDocument(nil)
    }

    final class Coordinator { var lastText: String? }
}
