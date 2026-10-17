import AppKit
import CryptoKit
import SwiftUI

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
    var savedOutput: URL?
    var saveError: String?
    var saving = false
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
    @Published var isSaving = false
    @Published var isImporting = false
    @Published var engineReady = false
    @Published var modelsReady = false
    @Published var status = L10n.text("文档留在你的 Mac 上")
    @Published var logs = ""
    @Published var errorMessage: String?
    @Published var showLogs = false
    @Published var showSettings = false
    @Published var markdown = ""
    @Published var html = ""
    @Published var previewLimited = false
    @Published var previewLoading = false
    @Published var previewMode = 0
    @Published var importing = false
    @Published var upstreamMessage = L10n.text("使用随客户端验证的锁定版本")
    @Published var queuePaused = false
    @Published private var reuseNotices: [UUID: Date] = [:]
    @AppStorage("recognizeScans") var ocr = true
    private let runner = ProcessRunner()
    private var cancelled = false
    private var quitting = false
    private var indices: [UUID: Int] = [:]
    private var previewRequest = UUID()
    private var intakeTasks: [UUID: Task<ScanResult, Never>] = [:]
    private var saveTask: Task<Void, Never>?
    private var pendingSaves: [UUID] = []
    private var previewTask: Task<(String, String, Bool), Error>?
    private let library: ResultLibrary
    private var reuseNoticeTask: Task<Void, Never>?
    private let session = FileManager.default.temporaryDirectory.appendingPathComponent("DoclingMac-\(UUID().uuidString)")
    let support: URL
    let backend: URL
    let cache: URL
    let results: URL
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

    init(backendURL: URL? = nil, cacheURL: URL? = nil, supportURL: URL? = nil, resultsURL: URL? = nil) {
        support = supportURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Docling Mac")
        backend = backendURL ?? Bundle.main.resourceURL!.appendingPathComponent("Backend")
        cache = cacheURL ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Docling Mac/Results")
        results = resultsURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Docling_Mac")
        library = ResultLibrary(root: results)
        configuration = try? RuntimeConfiguration.load(backend)
        engineReady = configuration != nil && FileManager.default.isExecutableFile(atPath: python.path)
            && lockHash != nil && (try? String(contentsOf: marker, encoding: .utf8)) == lockHash
        refreshModelsReady()
    }

    private func reindex() { indices = Dictionary(uniqueKeysWithValues: jobs.enumerated().map { ($0.element.id, $0.offset) }) }
    func chooseFiles() { NSApp.activate(); importing = true }

    func add(_ urls: [URL], startAutomatically: Bool = true) async {
        guard !quitting else { return }
        let taskID = UUID(), supported = Set(Self.extensions)
        let task = Task.detached(priority: .utility) { FileOperations.scan(urls, extensions: supported) }
        intakeTasks[taskID] = task; isImporting = true
        let result = await task.value
        intakeTasks[taskID] = nil; isImporting = !intakeTasks.isEmpty
        guard !quitting else { return }
        let existing = Dictionary(uniqueKeysWithValues: jobs.map { ($0.identity, $0) })
        var added = 0
        let promoted = result.files.map { input -> DocumentJob in
            if let job = existing[input.identity] {
                if job.ready { showReuseNotice(job.id) }
                return job
            }
            added += 1
            return DocumentJob(source: input.url, revision: input.revision)
        }
        let promotedIDs = Set(promoted.map(\.id))
        jobs = promoted + jobs.filter { !promotedIDs.contains($0.id) }
        reindex()
        if let first = promoted.first { selection = first.id }
        let reused = result.files.count - added
        if !isBusy { status = L10n.text("已添加 %@ 份", String(describing: added)) + (reused > 0 ? L10n.text("，%@ 份已有记录已移到顶部", String(describing: reused)) : "") }
        if !result.rejected.isEmpty {
            errorMessage = L10n.text("有 %@ 个项目未加入：\n", String(describing: result.rejected.count)) + result.rejected.prefix(12).joined(separator: "\n")
        }
        if startAutomatically { startWaitingAutomatically() }
    }

    private func startWaitingAutomatically() {
        guard engineReady, !queuePaused, !isBusy, !quitting, waiting > 0 else { return }
        Task { [weak self] in
            guard let self, !self.queuePaused else { return }
            await self.start()
        }
    }

    func showsReuseNotice(_ id: UUID) -> Bool { reuseNotices[id] != nil }

    private func showReuseNotice(_ id: UUID) {
        guard let configuration else { return }
        reuseNotices[id] = Date().addingTimeInterval(configuration.reuseNoticeSeconds)
        scheduleNoticeExpiry()
    }

    private func scheduleNoticeExpiry() {
        // One sleeping task serves the entire queue, including large cached batches.
        guard reuseNoticeTask == nil, let next = reuseNotices.values.min() else { return }
        let delay = UInt64(max(0, next.timeIntervalSinceNow) * 1_000_000_000)
        reuseNoticeTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self, !self.quitting else { return }
            self.reuseNoticeTask = nil
            self.reuseNotices = self.reuseNotices.filter { $0.value > Date() }
            self.scheduleNoticeExpiry()
        }
    }

    func install() async {
        guard !isBusy, !quitting else { return }
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/uv"),
            URL(fileURLWithPath: "/opt/homebrew/bin/uv"), URL(fileURLWithPath: "/usr/local/bin/uv")
        ]
        guard let uv = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            errorMessage = L10n.text("请先安装 uv（brew install uv），再点击准备引擎。安装说明见帮助菜单。"); return
        }
        guard let hash = lockHash, configuration != nil else {
            errorMessage = L10n.text("应用缺少引擎配置，请重新构建。"); return
        }
        isBusy = true; installing = true; cancelled = false; logs = ""
        status = L10n.text("正在准备引擎，首次安装需要几分钟…")
        defer { isBusy = false; installing = false; startWaitingAutomatically() }
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
            guard !cancelled, result.status == 0 else { throw ClientError(cancelled ? L10n.text("安装已取消") : result.errors) }
            try hash.write(to: marker, atomically: true, encoding: .utf8)
            engineReady = true; refreshModelsReady()
            status = L10n.text("本地引擎已就绪")
        } catch { status = L10n.text("引擎安装未完成"); if !cancelled { errorMessage = error.localizedDescription } }
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
        status = L10n.text("正在准备 PDF 模型，完成后验证离线加载…")
        var environment = engineEnvironment
        environment["HF_HUB_OFFLINE"] = allowNetwork ? "0" : "1"
        let result = try await runner.run(python,
            arguments: [backend.appendingPathComponent("models.py").path, "--prepare", "--state", modelState.path],
            environment: environment, line: { [weak self] text in self?.receive(text) }
        ) { [weak self] _, errors in self?.logs = errors }
        guard result.status == 0, !cancelled else {
            modelsReady = false
            throw ClientError(cancelled ? L10n.text("模型准备已取消") : WorkerEvent.parse(result.output).last?.message ?? result.errors)
        }
        refreshModelsReady()
        guard modelsReady else { throw ClientError(L10n.text("模型验证记录不完整，请重新准备模型。")) }
        status = L10n.text("模型已验证，可离线处理 PDF 与图片")
    }

    func prepareModels() async {
        guard engineReady, !isBusy, !quitting else { return }
        isBusy = true; cancelled = false; logs = ""
        defer { isBusy = false; if modelsReady { startWaitingAutomatically() } }
        do { try await prepareModelsInBackground(allowNetwork: !modelsReady) }
        catch { if !cancelled { errorMessage = error.localizedDescription }; status = error.localizedDescription }
    }

    func checkUpdates() async {
        guard engineReady, !isBusy, !quitting else { return }
        isBusy = true; cancelled = false; upstreamMessage = L10n.text("正在查询官方版本…")
        defer { isBusy = false; startWaitingAutomatically() }
        do {
            let result = try await runner.run(python, arguments: [backend.appendingPathComponent("models.py").path, "--updates"],
                environment: engineEnvironment) { [weak self] _, errors in self?.logs = errors }
            guard result.status == 0, let update = WorkerEvent.parse(result.output).last(where: { $0.event == "update" }) else {
                throw ClientError(WorkerEvent.parse(result.output).last?.message ?? result.errors)
            }
            upstreamMessage = L10n.text("当前 %@ · 上游 %@", String(describing: update.current ?? ""), String(describing: update.latest ?? "")) + (update.available == true ? L10n.text("；有新版本，需适配后随客户端更新") : L10n.text("；已是上游当前版本"))
        } catch { upstreamMessage = L10n.text("检查失败：%@", String(describing: error.localizedDescription)) }
    }

    func start() async {
        guard engineReady, let config = configuration, !isBusy, waiting > 0, !quitting else { return }
        isBusy = true; cancelled = false; queuePaused = false; logs = ""
        defer { isBusy = false; if cancelled { status = L10n.text("已停止，尚未开始的文档保留在队列中") } }
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
                if let saveTask { await saveTask.value }
                if cancelled { for i in jobs.indices where jobs[i].state == .running { jobs[i].state = .cancelled }; break }
                guard result.status == 0, WorkerEvent.parse(result.output).contains(where: { $0.event == "batch_complete" }) else {
                    throw ClientError(WorkerEvent.parse(result.output).last(where: { $0.event == "error" })?.message ?? result.errors)
                }
                status = L10n.text("已完成 %@ 份", String(describing: completed)) + (reused > 0 ? L10n.text(" · %@ 份复用结果", String(describing: reused)) : "") + L10n.text(" · 结果已自动保存")
                if jobs.contains(where: { $0.saveError != nil }) { status = L10n.text("部分结果保存失败，请在文档中重试保存") }
            }
        } catch {
            queuePaused = true
            for i in jobs.indices where jobs[i].state == .running {
                jobs[i].state = cancelled ? .cancelled : .failed
                jobs[i].message = error.localizedDescription
            }
            status = cancelled ? L10n.text("已停止") : L10n.text("后台任务未完成，可查看日志")
            if !cancelled { errorMessage = error.localizedDescription }
        }
        if let saveTask { await saveTask.value }
    }

    private func receive(_ line: String) {
        guard let event = WorkerEvent.parse(line).first, !quitting || event.event == "complete" else { return }
        if let message = event.message, !cancelled { status = L10n.text(message) }
        guard let id = event.id, let index = indices[id] else { return }
        switch event.event {
        case "started": jobs[index].state = .running
        case "complete":
            jobs[index].state = event.partial == true ? .partial : .done
            jobs[index].message = (event.warnings ?? []).joined(separator: "\n")
            jobs[index].pages = event.pages ?? 0; jobs[index].seconds = event.seconds ?? 0
            jobs[index].cached = event.cached ?? false
            jobs[index].output = event.output.map { URL(fileURLWithPath: $0) }
            saveResult(id)
            if event.cached == true { showReuseNotice(id) }
            if selection == id && !quitting { loadPreview() }
        case "error": jobs[index].state = .failed; jobs[index].message = event.message.map { L10n.text($0) } ?? L10n.text("转换失败")
        default: break
        }
    }

    func cancel() { cancelled = true; queuePaused = true; status = L10n.text("正在停止…"); runner.cancel() }

    func retry(_ id: UUID, startAutomatically: Bool = true) {
        guard !isBusy, !isSaving, let index = indices[id] else { return }
        let previous = jobs[index]
        let replacement = DocumentJob(source: previous.source, revision: previous.revision)
        jobs[index] = replacement; reindex(); selection = replacement.id; loadPreview()
        if startAutomatically { queuePaused = false; startWaitingAutomatically() }
    }

    func remove(_ id: UUID) {
        guard !isBusy, !isSaving else { return }
        jobs.removeAll { $0.id == id }; reindex()
        reuseNotices[id] = nil
        if selection == id { selection = jobs.first?.id; loadPreview() }
    }

    func clearQueue() {
        guard !isBusy, !isImporting, !isSaving else { return }
        jobs.removeAll(); reindex(); selection = nil; loadPreview(); status = L10n.text("队列已清空，已保存文件仍保留在 Docling_Mac")
        queuePaused = false
        reuseNoticeTask?.cancel(); reuseNoticeTask = nil; reuseNotices.removeAll()
        Task {
            guard !isBusy, !quitting else { return }
            isBusy = true
            defer { isBusy = false; startWaitingAutomatically() }
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
        markdown = ""; html = ""; previewLimited = false; previewLoading = false
        previewTask?.cancel()
        let previous = previewTask
        let request = UUID(); previewRequest = request
        guard let output = selected?.output, let config = configuration else { return }
        let rendered = previewMode == 0
        previewLoading = true
        Task {
            // Cancel and join old I/O before allocating another large preview.
            if let previous { _ = try? await previous.value }
            guard request == previewRequest, !quitting else { return }
            let task = Task.detached(priority: .utility) {
                try FileOperations.preview(output, maxBytes: config.previewMaxBytes, rendered: rendered)
            }
            previewTask = task
            defer { if request == previewRequest { previewLoading = false; previewTask = nil } }
            do {
                let content = try await task.value
                guard request == previewRequest, !quitting else { return }
                markdown = content.0; html = content.1; previewLimited = content.2
            } catch is CancellationError {
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
                status = L10n.text("完整 Markdown 已复制")
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func openResults(_ folder: URL? = nil) {
        do {
            try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            if !NSWorkspace.shared.open(folder ?? results) { throw ClientError(L10n.text("无法打开结果文件夹。")) }
        } catch { errorMessage = error.localizedDescription }
    }

    func saveResult(_ id: UUID) {
        guard let index = indices[id], jobs[index].ready, jobs[index].savedOutput == nil,
              !jobs[index].saving, jobs[index].output != nil else { return }
        jobs[index].saving = true; jobs[index].saveError = nil
        pendingSaves.append(id)
        guard saveTask == nil else { return }
        isSaving = true
        saveTask = Task {
            defer {
                isSaving = false; saveTask = nil
                if !isBusy && !quitting {
                    status = jobs.contains(where: { $0.saveError != nil })
                        ? L10n.text("部分结果保存失败，请在文档中重试保存") : L10n.text("结果已自动保存到 Docling_Mac")
                }
            }
            while !pendingSaves.isEmpty {
                let id = pendingSaves.removeFirst()
                guard let index = indices[id], let output = jobs[index].output else { continue }
                let source = jobs[index].source
                do {
                    let folder = try await library.save(output: output, source: source)
                    if let current = indices[id] { jobs[current].savedOutput = folder }
                } catch {
                    if let current = indices[id] { jobs[current].saveError = error.localizedDescription }
                }
                if let current = indices[id] { jobs[current].saving = false }
            }
        }
    }

    @discardableResult
    func shutdown() async -> Bool {
        quitting = true; cancelled = true; queuePaused = true
        reuseNoticeTask?.cancel(); reuseNoticeTask = nil
        let scans = Array(intakeTasks.values)
        for task in scans { task.cancel() }
        previewTask?.cancel()
        await runner.stopAndWait()
        for task in scans { _ = await task.value }
        // Completed conversions are durable before cache/session cleanup, even on quit.
        if let saveTask { await saveTask.value }
        if let previewTask { _ = try? await previewTask.value }
        let unsaved = jobs.filter { $0.ready && $0.savedOutput == nil }
        guard unsaved.isEmpty else {
            quitting = false
            errorMessage = L10n.text("还有 %@ 份结果未能保存，已取消退出。请检查 Docling_Mac 文件夹和磁盘空间，再点击文档中的「重试保存」。临时结果仍保留，可以继续查看。", String(describing: unsaved.count))
            return false
        }
        do { try await pruneCache() }
        catch { NSLog("Docling cache cleanup: %@", error.localizedDescription) }
        try? FileManager.default.removeItem(at: session)
        return true
    }
}

struct ClientError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message.isEmpty ? L10n.text("引擎意外退出，请查看运行日志。") : message }
    var errorDescription: String? { L10n.text(message) }
}
