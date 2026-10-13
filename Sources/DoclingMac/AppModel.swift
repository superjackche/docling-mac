import AppKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

enum JobState: String {
    case pending = "等待转换", running = "正在解析", done = "已完成"
    case partial = "部分完成", failed = "转换失败", cancelled = "已取消"
}

struct DocumentJob: Identifiable {
    let id = UUID()
    let source: URL
    var revision = ""
    var state: JobState = .pending
    var message = ""
    var output: URL?
    var pages = 0
    var seconds = 0.0
    var cached = false
    var ready: Bool { state == .done || state == .partial }
    var identity: String { source.path + "|" + revision }
}

struct WorkerEvent: Decodable {
    let event: String
    var id: UUID?
    var message: String?
    var partial: Bool?
    var warnings: [String]?
    var pages: Int?
    var cached: Bool?
    var output: String?
    var seconds: Double?
    var current: String?
    var latest: String?
    var available: Bool?

    static func parse(_ text: String) -> [WorkerEvent] {
        text.split(separator: "\n").compactMap {
            try? JSONDecoder().decode(WorkerEvent.self, from: Data($0.utf8))
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let extensions = ["pdf", "docx", "pptx", "xlsx", "html", "htm", "md", "csv", "png", "jpg", "jpeg", "tiff", "tif", "bmp", "webp"]
    private static let modelFormats: Set<String> = ["pdf", "png", "jpg", "jpeg", "tiff", "tif", "bmp", "webp"]
    @Published var jobs: [DocumentJob] = []
    @Published var selection: UUID?
    @Published var isBusy = false
    @Published var installing = false
    @Published var isExporting = false
    @Published var isImporting = false
    @Published var engineReady = false
    @Published var modelsReady = false
    @Published var status = "文档留在你的 Mac 上"
    @Published var logs = ""
    @Published var errorMessage: String?
    @Published var showLogs = false
    @Published var showSettings = false
    @Published var markdown = ""
    @Published var html = ""
    @Published var previewLimited = false
    @Published var importing = false
    @Published var upstreamMessage = "使用随客户端验证的锁定版本"
    @AppStorage("recognizeScans") var ocr = true
    private let runner = ProcessRunner()
    private var cancelled = false
    private var quitting = false
    private var indices: [UUID: Int] = [:]
    private var previewRequest = UUID()
    private var intakeTasks: [UUID: Task<ScanResult, Never>] = [:]
    private var exportTask: Task<ExportReport, Error>?
    private let session = FileManager.default.temporaryDirectory.appendingPathComponent("DoclingMac-\(UUID().uuidString)")
    let support: URL
    let backend: URL
    let cache: URL
    let configuration: RuntimeConfiguration?

    var selected: DocumentJob? { jobs.first { $0.id == selection } }
    var waiting: Int { jobs.filter { $0.state == .pending }.count }
    var completed: Int { jobs.filter(\.ready).count }
    var reused: Int { jobs.filter { $0.ready && $0.cached }.count }
    var python: URL { support.appendingPathComponent("runtime/bin/python3") }
    private var marker: URL { support.appendingPathComponent("engine.lock") }
    private var modelState: URL { support.appendingPathComponent("models.json") }
    private var lockHash: String? {
        guard let data = try? Data(contentsOf: backend.appendingPathComponent("uv.lock")) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private var engineEnvironment: [String: String] {
        ["PYTHONUNBUFFERED": "1", "PYTHONDONTWRITEBYTECODE": "1", "HF_HUB_DISABLE_TELEMETRY": "1", "HF_HUB_OFFLINE": "1",
         "HF_HOME": support.appendingPathComponent("models").path]
    }

    init(backendURL: URL? = nil, cacheURL: URL? = nil, supportURL: URL? = nil) {
        support = supportURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Docling Mac")
        backend = backendURL ?? Bundle.main.resourceURL!.appendingPathComponent("Backend")
        cache = cacheURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Docling Mac/Results")
        configuration = try? RuntimeConfiguration.load(backend)
        engineReady = configuration != nil && FileManager.default.isExecutableFile(atPath: python.path)
            && lockHash != nil && (try? String(contentsOf: marker, encoding: .utf8)) == lockHash
        refreshModelsReady()
    }

    private func reindex() { indices = Dictionary(uniqueKeysWithValues: jobs.enumerated().map { ($0.element.id, $0.offset) }) }
    func chooseFiles() { NSApp.activate(); importing = true }

    func add(_ urls: [URL]) async {
        guard !quitting else { return }
        let taskID = UUID(), supported = Set(Self.extensions)
        let task = Task.detached(priority: .utility) { FileOperations.scan(urls, extensions: supported) }
        intakeTasks[taskID] = task; isImporting = true
        let result = await task.value
        intakeTasks[taskID] = nil; isImporting = !intakeTasks.isEmpty
        guard !quitting else { return }
        var known = Set(jobs.map(\.identity))
        let additions = result.files.filter { known.insert($0.identity).inserted }.map {
            DocumentJob(source: $0.url, revision: $0.revision)
        }
        jobs.append(contentsOf: additions)
        reindex()
        if selection == nil { selection = jobs.first?.id }
        let skipped = result.files.count - additions.count
        if !isBusy { status = "已添加 \(additions.count) 份" + (skipped > 0 ? "，跳过 \(skipped) 份未改变的文件" : "") }
        if !result.rejected.isEmpty {
            errorMessage = "有 \(result.rejected.count) 个项目未加入：\n" + result.rejected.prefix(12).joined(separator: "\n")
        }
    }

    func install() async {
        guard !isBusy, !quitting else { return }
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/uv"),
            URL(fileURLWithPath: "/opt/homebrew/bin/uv"), URL(fileURLWithPath: "/usr/local/bin/uv")
        ]
        guard let uv = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            errorMessage = "请先安装 uv（brew install uv），再点击准备引擎。安装说明见帮助菜单。"; return
        }
        guard let hash = lockHash, configuration != nil else {
            errorMessage = "应用缺少引擎配置，请重新构建。"; return
        }
        isBusy = true; installing = true; cancelled = false; logs = ""
        status = "正在准备引擎，首次安装需要几分钟…"
        defer { isBusy = false; installing = false }
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            // uv can partially change an existing environment before failing or
            // being cancelled. Only a completed sync may restore its ready marker.
            if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
            engineReady = false; modelsReady = false
            let result = try await runner.run(uv,
                arguments: ["sync", "--project", backend.path, "--locked", "--no-dev", "--python", "3.12"],
                environment: ["UV_PROJECT_ENVIRONMENT": support.appendingPathComponent("runtime").path, "UV_NO_PROGRESS": "1"]
            ) { [weak self] _, errors in self?.logs = errors }
            guard !cancelled, result.status == 0 else { throw ClientError(cancelled ? "安装已取消" : result.errors) }
            try hash.write(to: marker, atomically: true, encoding: .utf8)
            engineReady = true; refreshModelsReady()
            status = "本地引擎已就绪"
        } catch { status = "引擎安装未完成"; if !cancelled { errorMessage = error.localizedDescription } }
    }

    private func refreshModelsReady() {
        modelsReady = false
        guard let data = try? Data(contentsOf: modelState),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              record["engine_lock"] as? String == lockHash,
              let models = record["models"] as? [[String: String]], !models.isEmpty else { return }
        modelsReady = models.allSatisfy { model in
            guard let repo = model["repo"], let snapshot = model["snapshot"] else { return false }
            let path = support.appendingPathComponent("models/hub/models--" + repo.replacingOccurrences(of: "/", with: "--") + "/snapshots/" + snapshot)
            return FileManager.default.fileExists(atPath: path.path)
        }
    }

    private func prepareModelsInBackground(allowNetwork: Bool = true) async throws {
        status = "正在准备 PDF 模型，完成后验证离线加载…"
        var environment = engineEnvironment
        environment["HF_HUB_OFFLINE"] = allowNetwork ? "0" : "1"
        let result = try await runner.run(python,
            arguments: [backend.appendingPathComponent("models.py").path, "--prepare", "--state", modelState.path],
            environment: environment, line: { [weak self] text in self?.receive(text) }
        ) { [weak self] _, errors in self?.logs = errors }
        guard result.status == 0, !cancelled else {
            modelsReady = false
            throw ClientError(cancelled ? "模型准备已取消" : WorkerEvent.parse(result.output).last?.message ?? result.errors)
        }
        refreshModelsReady()
        guard modelsReady else { throw ClientError("模型验证记录不完整，请重新准备模型。") }
        status = "模型已验证，可离线处理 PDF 与图片"
    }

    func prepareModels() async {
        guard engineReady, !isBusy, !quitting else { return }
        isBusy = true; cancelled = false; logs = ""
        defer { isBusy = false }
        do { try await prepareModelsInBackground(allowNetwork: !modelsReady) }
        catch { if !cancelled { errorMessage = error.localizedDescription }; status = error.localizedDescription }
    }

    func checkUpdates() async {
        guard engineReady, !isBusy, !quitting else { return }
        isBusy = true; cancelled = false; upstreamMessage = "正在查询官方版本…"
        defer { isBusy = false }
        do {
            let result = try await runner.run(python, arguments: [backend.appendingPathComponent("models.py").path, "--updates"],
                environment: engineEnvironment) { [weak self] _, errors in self?.logs = errors }
            guard result.status == 0, let update = WorkerEvent.parse(result.output).last(where: { $0.event == "update" }) else {
                throw ClientError(WorkerEvent.parse(result.output).last?.message ?? result.errors)
            }
            upstreamMessage = "当前 \(update.current ?? "") · 上游 \(update.latest ?? "")" + (update.available == true ? "；有新版本，需适配后随客户端更新" : "；已是上游当前版本")
        } catch { upstreamMessage = "检查失败：\(error.localizedDescription)" }
    }

    func start() async {
        guard engineReady, let config = configuration, !isBusy, waiting > 0, !quitting else { return }
        isBusy = true; cancelled = false; logs = ""
        defer { isBusy = false; if cancelled { status = "已停止，尚未开始的文档保留在队列中" } }
        do {
            while waiting > 0 && !cancelled {
                let batch = jobs.filter { $0.state == .pending }
                if !modelsReady && batch.contains(where: { Self.modelFormats.contains($0.source.pathExtension.lowercased()) }) {
                    try await prepareModelsInBackground()
                }
                guard !cancelled else { break }
                try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
                let manifest = session.appendingPathComponent("batch-\(UUID().uuidString).json")
                let modelBytes = (try? Data(contentsOf: modelState)) ?? Data()
                let modelHash = SHA256.hash(data: modelBytes).map { String(format: "%02x", $0) }.joined()
                let value: [String: Any] = [
                    "jobs": batch.map { ["id": $0.id.uuidString, "source": $0.source.path] },
                    "ocr": ocr, "cache": cache.path, "output": session.path,
                    "protected": jobs.compactMap { $0.output?.path }, "models_identity": modelHash
                ]
                try JSONSerialization.data(withJSONObject: value).write(to: manifest, options: .atomic)
                let result = try await runner.run(python,
                    arguments: [backend.appendingPathComponent("worker.py").path, "--batch", manifest.path],
                    environment: engineEnvironment, processGroup: true, logLimit: config.logMaxBytes,
                    line: { [weak self] text in self?.receive(text) }
                ) { [weak self] _, errors in self?.logs = errors }
                try? FileManager.default.removeItem(at: manifest)
                if cancelled { for i in jobs.indices where jobs[i].state == .running { jobs[i].state = .cancelled }; break }
                guard result.status == 0, WorkerEvent.parse(result.output).contains(where: { $0.event == "batch_complete" }) else {
                    throw ClientError(WorkerEvent.parse(result.output).last(where: { $0.event == "error" })?.message ?? result.errors)
                }
                status = "已完成 \(completed) 份" + (reused > 0 ? " · \(reused) 份复用结果" : "") + " · 模型已释放"
            }
        } catch {
            for i in jobs.indices where jobs[i].state == .running {
                jobs[i].state = cancelled ? .cancelled : .failed
                jobs[i].message = error.localizedDescription
            }
            status = cancelled ? "已停止" : "后台任务未完成，可查看日志"
            if !cancelled { errorMessage = error.localizedDescription }
        }
    }

    private func receive(_ line: String) {
        guard !quitting, let event = WorkerEvent.parse(line).first else { return }
        if let message = event.message, !cancelled { status = message }
        guard let id = event.id, let index = indices[id] else { return }
        switch event.event {
        case "started": jobs[index].state = .running
        case "complete":
            jobs[index].state = event.partial == true ? .partial : .done
            jobs[index].message = (event.warnings ?? []).joined(separator: "\n")
            jobs[index].pages = event.pages ?? 0; jobs[index].seconds = event.seconds ?? 0
            jobs[index].cached = event.cached ?? false
            jobs[index].output = event.output.map { URL(fileURLWithPath: $0) }
            if selection == id { loadPreview() }
        case "error": jobs[index].state = .failed; jobs[index].message = event.message ?? "转换失败"
        default: break
        }
    }

    func cancel() { cancelled = true; status = "正在停止…"; runner.cancel() }

    func retry(_ id: UUID) {
        guard !isBusy, let index = indices[id] else { return }
        let previous = jobs[index]
        let replacement = DocumentJob(source: previous.source, revision: previous.revision)
        jobs[index] = replacement; reindex(); selection = replacement.id; loadPreview()
    }

    func remove(_ id: UUID) {
        guard !isBusy else { return }
        jobs.removeAll { $0.id == id }; reindex()
        if selection == id { selection = jobs.first?.id; loadPreview() }
    }

    func clearQueue() {
        guard !isBusy, !isImporting, !isExporting else { return }
        jobs.removeAll(); reindex(); selection = nil; loadPreview(); status = "队列已清空，转换缓存仍可复用"
        Task {
            guard !isBusy, !quitting else { return }
            isBusy = true
            defer { isBusy = false }
            do { try await pruneCache() } catch { errorMessage = error.localizedDescription }
        }
    }

    private func pruneCache() async throws {
        guard engineReady, FileManager.default.fileExists(atPath: cache.path) else { return }
        let result = try await runner.run(python,
            arguments: [backend.appendingPathComponent("worker.py").path, "--prune-cache", cache.path],
            environment: engineEnvironment) { _, _ in }
        guard result.status == 0 else { throw ClientError(result.errors) }
    }

    func loadPreview() {
        markdown = ""; html = ""; previewLimited = false
        let request = UUID(); previewRequest = request
        guard let output = selected?.output, let config = configuration else { return }
        Task {
            do {
                let content = try await Task.detached(priority: .utility) { try FileOperations.preview(output, maxBytes: config.previewMaxBytes) }.value
                guard request == previewRequest, !quitting else { return }
                markdown = content.0; html = content.1; previewLimited = content.2
            } catch { if request == previewRequest && !quitting { errorMessage = error.localizedDescription } }
        }
    }

    func copyMarkdown() {
        guard let output = selected?.output else { return }
        Task {
            do {
                let text = try await Task.detached(priority: .utility) {
                    try String(contentsOf: output.appendingPathComponent("document.md"), encoding: .utf8)
                }.value
                guard !quitting else { return }
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                status = "完整 Markdown 已复制"
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func export(_ ext: String) {
        guard !isExporting, let job = selected, let output = job.output else { return }
        NSApp.activate()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = job.source.deletingPathExtension().lastPathComponent + "." + ext
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { await self?.saveExport(from: output.appendingPathComponent("document." + ext), to: url,
                                         originalFilename: job.source.lastPathComponent) }
        }
    }

    func saveExport(from source: URL, to url: URL, originalFilename: String? = nil) async {
        guard !isExporting else { return }
        isExporting = true
        let inputs = jobs.map(\.source)
        let task = Task.detached(priority: .utility) {
            try FileOperations.save(source, to: url, protecting: inputs, originalFilename: originalFilename)
            return ExportReport(directory: url, count: 1)
        }
        exportTask = task
        defer { isExporting = false; exportTask = nil }
        do { _ = try await task.value; if !quitting { status = "已导出 \(url.lastPathComponent)" } }
        catch { if !quitting { errorMessage = error.localizedDescription } }
    }

    func exportAll(_ ext: String) {
        guard !isExporting, completed > 0 else { return }
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "导出到这里"
        panel.message = "将在此创建一个新文件夹，同名文档自动编号。"
        panel.begin { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            Task { await self?.exportBatch(to: folder, extension: ext) }
        }
    }

    func exportBatch(to folder: URL, extension ext: String) async {
        guard !isExporting else { return }
        let files = jobs.filter(\.ready).compactMap { job -> ExportFile? in
            guard let output = job.output else { return nil }
            return ExportFile(source: output.appendingPathComponent("document." + ext),
                              name: job.source.deletingPathExtension().lastPathComponent + "." + ext,
                              originalFilename: job.source.lastPathComponent)
        }
        isExporting = true
        let task = Task.detached(priority: .utility) { try FileOperations.exportBatch(files, to: folder) }
        exportTask = task
        defer { isExporting = false; exportTask = nil }
        do {
            let report = try await task.value
            guard !quitting else { return }
            status = "已导出 \(report.count) 份到 \(report.directory.lastPathComponent)"
            if !report.errors.isEmpty { errorMessage = report.errors.prefix(12).joined(separator: "\n") }
        } catch { if !quitting { errorMessage = error.localizedDescription } }
    }

    func shutdown() async {
        quitting = true; cancelled = true
        let scans = Array(intakeTasks.values)
        for task in scans { task.cancel() }
        exportTask?.cancel()
        await runner.stopAndWait()
        for task in scans { _ = await task.value }
        if let exportTask { _ = try? await exportTask.value }
        do { try await pruneCache() }
        catch { NSLog("Docling cache cleanup: %@", error.localizedDescription) }
        try? FileManager.default.removeItem(at: session)
    }
}

struct ClientError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message.isEmpty ? "引擎意外退出，请查看运行日志。" : message }
    var errorDescription: String? { message }
}
