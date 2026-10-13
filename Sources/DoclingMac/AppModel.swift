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
    var state: JobState = .pending
    var message = ""
    var output: URL?
    var pages = 0
    var seconds = 0.0
    var ready: Bool { state == .done || state == .partial }
}

struct WorkerEvent: Decodable {
    let event: String
    var message: String?
    var partial: Bool?
    var warnings: [String]?
    var pages: Int?

    static func parse(_ text: String) -> [WorkerEvent] {
        text.split(separator: "\n").compactMap {
            try? JSONDecoder().decode(WorkerEvent.self, from: Data($0.utf8))
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let extensions = ["pdf", "docx", "pptx", "xlsx", "html", "htm", "md", "csv", "png", "jpg", "jpeg", "tiff", "tif", "bmp", "webp"]
    @Published var jobs: [DocumentJob] = []
    @Published var selection: UUID?
    @Published var isBusy = false
    @Published var installing = false
    @Published var engineReady = false
    @Published var status = "文档留在你的 Mac 上"
    @Published var logs = ""
    @Published var errorMessage: String?
    @Published var showLogs = false
    @Published var markdown = ""
    @Published var html = ""
    @Published var importing = false
    @AppStorage("recognizeScans") var ocr = true
    private let runner = ProcessRunner()
    private var cancelled = false
    private let session = FileManager.default.temporaryDirectory.appendingPathComponent("DoclingMac-\(UUID().uuidString)")
    let support: URL
    let backend: URL

    var selected: DocumentJob? { jobs.first { $0.id == selection } }
    var waiting: Int { jobs.filter { $0.state == .pending }.count }
    var python: URL { support.appendingPathComponent("runtime/bin/python3") }
    private var marker: URL { support.appendingPathComponent("engine.lock") }
    private var lockHash: String? {
        guard let data = try? Data(contentsOf: backend.appendingPathComponent("uv.lock")) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    init() {
        support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Docling Mac")
        backend = Bundle.main.resourceURL!.appendingPathComponent("Backend")
        engineReady = FileManager.default.isExecutableFile(atPath: python.path)
            && lockHash != nil && (try? String(contentsOf: marker, encoding: .utf8)) == lockHash
    }

    func chooseFiles() {
        NSApp.activate()
        importing = true
    }

    func add(_ urls: [URL]) {
        var rejected: [String] = []
        for url in urls {
            guard url.isFileURL, Self.extensions.contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                rejected.append(url.lastPathComponent)
                continue
            }
            if jobs.contains(where: { $0.source == url }) { continue }
            let job = DocumentJob(source: url)
            jobs.append(job)
            if selection == nil { selection = job.id }
        }
        if !rejected.isEmpty { errorMessage = "以下项目不是支持的文档文件：\n" + rejected.joined(separator: "\n") }
    }

    func install() async {
        guard !isBusy else { return }
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/uv"),
            URL(fileURLWithPath: "/opt/homebrew/bin/uv"), URL(fileURLWithPath: "/usr/local/bin/uv")
        ]
        guard let uv = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            errorMessage = "请先安装 uv（brew install uv），再点击准备引擎。安装说明见帮助菜单。"
            return
        }
        guard let hash = lockHash else {
            errorMessage = "应用缺少引擎锁文件，请用 scripts/build.sh 重新构建。"
            return
        }
        isBusy = true; installing = true; logs = ""
        status = "正在准备引擎，首次安装需要几分钟…"
        defer { isBusy = false; installing = false }
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let result = try await runner.run(uv,
                arguments: ["sync", "--project", backend.path, "--locked", "--no-dev", "--python", "3.12"],
                environment: ["UV_PROJECT_ENVIRONMENT": support.appendingPathComponent("runtime").path, "UV_NO_PROGRESS": "1"]
            ) { [weak self] _, errors in self?.logs = errors }
            guard result.status == 0 else { throw ClientError(result.errors) }
            try hash.write(to: marker, atomically: true, encoding: .utf8)
            engineReady = true
            status = "本地引擎已就绪"
        } catch {
            status = "引擎安装未完成"
            errorMessage = error.localizedDescription
        }
    }

    func start() async {
        guard engineReady, !isBusy, waiting > 0 else { return }
        isBusy = true; cancelled = false
        let recognize = ocr
        defer { isBusy = false; if cancelled { status = "已停止，剩余文档保留在队列中" } }
        while let index = jobs.firstIndex(where: { $0.state == .pending }), !cancelled {
            let id = jobs[index].id
            let destination = session.appendingPathComponent(id.uuidString)
            jobs[index].state = .running
            selection = id
            loadPreview()
            let start = Date()
            logs = ""
            do {
                try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
                var args = [backend.appendingPathComponent("worker.py").path, jobs[index].source.path, destination.path]
                if recognize { args.append("--ocr") }
                let result = try await runner.run(python, arguments: args,
                    environment: ["PYTHONUNBUFFERED": "1", "HF_HUB_DISABLE_TELEMETRY": "1",
                                  "HF_HOME": support.appendingPathComponent("models").path], processGroup: true
                ) { [weak self] output, errors in
                    guard let self else { return }
                    self.logs = errors
                    if let message = WorkerEvent.parse(output).last(where: { $0.event == "status" })?.message {
                        self.status = message
                    }
                }
                if cancelled { jobs[index].state = .cancelled; break }
                let events = WorkerEvent.parse(result.output)
                guard result.status == 0, let completed = events.last(where: { $0.event == "complete" }) else {
                    throw ClientError(events.last(where: { $0.event == "error" })?.message ?? result.errors)
                }
                for file in ["document.md", "document.html", "document.json"] {
                    guard FileManager.default.fileExists(atPath: destination.appendingPathComponent(file).path) else {
                        throw ClientError("引擎未生成完整的导出文件。")
                    }
                }
                jobs[index].state = completed.partial == true ? .partial : .done
                jobs[index].message = (completed.warnings ?? []).joined(separator: "\n")
                jobs[index].pages = completed.pages ?? 0
                jobs[index].seconds = Date().timeIntervalSince(start)
                jobs[index].output = destination
                status = "转换完成"
            } catch {
                jobs[index].state = cancelled ? .cancelled : .failed
                jobs[index].message = error.localizedDescription
                status = cancelled ? "已取消" : "转换失败，可查看详情后重试"
            }
            if selection == id { loadPreview() }
        }
    }

    func cancel() { cancelled = true; status = "正在停止…"; runner.cancel() }

    func retry(_ id: UUID) {
        guard !isBusy, let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        // A retry gets a fresh output directory, so partial files cannot look complete.
        let replacement = DocumentJob(source: jobs[index].source)
        jobs[index] = replacement
        selection = replacement.id
        loadPreview()
    }

    func remove(_ id: UUID) {
        guard !isBusy else { return }
        jobs.removeAll { $0.id == id }
        if selection == id { selection = jobs.first?.id; loadPreview() }
    }

    func loadPreview() {
        markdown = ""; html = ""
        guard let output = selected?.output else { return }
        do {
            markdown = try String(contentsOf: output.appendingPathComponent("document.md"), encoding: .utf8)
            html = try String(contentsOf: output.appendingPathComponent("document.html"), encoding: .utf8)
        } catch { errorMessage = "无法读取转换结果：\(error.localizedDescription)" }
    }

    func copyMarkdown() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        status = "Markdown 已复制"
    }

    func export(_ ext: String) {
        guard let job = selected, let output = job.output else { return }
        NSApp.activate()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = job.source.deletingPathExtension().lastPathComponent + "." + ext
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.saveExport(from: output.appendingPathComponent("document." + ext), to: url)
        }
    }

    func saveExport(from source: URL, to url: URL) {
        let target = url.resolvingSymlinksInPath().standardizedFileURL
        guard !jobs.contains(where: { $0.source.resolvingSymlinksInPath().standardizedFileURL == target }) else {
            errorMessage = "请另存为新文件，避免覆盖输入文档。"; return
        }
        do {
            let data = try Data(contentsOf: source)
            try data.write(to: url, options: .atomic)
            status = "已导出 \(url.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { errorMessage = "导出失败：\(error.localizedDescription)" }
    }

    func cleanup() {
        runner.cancel()
        try? FileManager.default.removeItem(at: session)
    }
}

struct ClientError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message.isEmpty ? "引擎意外退出，请查看运行日志。" : message }
    var errorDescription: String? { message }
}
