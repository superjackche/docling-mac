import AppKit

// Standalone checks also run on Macs with Command Line Tools and no XCTest.
@main
struct ClientChecks {
    @MainActor
    static func main() async throws {
        let literal = "中文 with spaces; $(not-a-shell)"
        let result = try await ProcessRunner().run(URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", literal]) { _, _ in }
        precondition(result.status == 0 && result.output == literal, "Arguments must not go through a shell")
        let failed = try await ProcessRunner().run(URL(fileURLWithPath: "/usr/bin/false"), arguments: []) { _, _ in }
        precondition(failed.status != 0, "Exit status must be preserved")
        print("PASS literal arguments and exit status")

        let runner = ProcessRunner()
        let start = Date()
        let task = Task { try await runner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"]) { _, _ in } }
        try await Task.sleep(nanoseconds: 200_000_000)
        runner.cancel()
        let stopped = try await task.value
        precondition(stopped.status != 0 && Date().timeIntervalSince(start) < 3, "Cancellation must stop the child")
        print("PASS process cancellation")

        var launchFailed = false
        do {
            _ = try await ProcessRunner().run(URL(fileURLWithPath: "/not-an-executable"), arguments: []) { _, _ in }
        } catch { launchFailed = true }
        precondition(launchFailed, "Launch failures must propagate")
        print("PASS launch failure")

        let events = WorkerEvent.parse("{\"event\":\"status\",\"message\":\"工作中\"}\n{\"event\":\"complete\",\"partial\":true,\"warnings\":[\"page failed\"],\"pages\":2}\n{\"event\":")
        precondition(events.count == 2 && events.last?.partial == true && events.last?.warnings == ["page failed"])
        print("PASS structured partial success and incomplete event")
        let longEvent = "{\"event\":\"complete\",\"partial\":true,\"warnings\":[\"" + String(repeating: "w", count: 40_000) + "\"]}"
        let longResult = try await ProcessRunner().run(URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", longEvent]) { _, _ in }
        precondition(WorkerEvent.parse(longResult.output).last?.warnings?.first?.count == 40_000)
        print("PASS completion protocol is not truncated with UI logs")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("中文 file.pdf")
        try Data("test".utf8).write(to: source)
        let model = AppModel()
        model.add([source, source, directory, URL(string: "https://example.com/file.pdf")!])
        precondition(model.jobs.count == 1 && model.errorMessage != nil)
        let alias = directory.appendingPathComponent("alias.pdf")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        model.errorMessage = nil
        model.saveExport(from: source, to: alias)
        precondition(model.errorMessage != nil && (try? String(contentsOf: source, encoding: .utf8)) == "test")
        print("PASS export refuses input aliases")
        let oldID = model.selection!
        model.jobs[0].state = .failed
        model.retry(oldID)
        precondition(model.jobs[0].state == .pending && model.jobs[0].id != oldID)
        model.remove(model.jobs[0].id)
        precondition(model.jobs.isEmpty && model.selection == nil)
        print("PASS queue validation, deduplication, retry, removal")

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let worker = try await ProcessRunner().run(model.python, arguments: [root.appendingPathComponent("Backend/worker.py").path,
            directory.appendingPathComponent("missing.pdf").path, directory.appendingPathComponent("output").path], processGroup: true) { _, _ in }
        precondition(worker.status == 1 && WorkerEvent.parse(worker.output).last?.event == "error",
                     "Foundation-launched Python must reach the worker protocol, even as an existing process-group leader")
        print("PASS native Python launch protocol")

        model.add([root.appendingPathComponent("Tests/fixtures/sample.html")])
        precondition(model.engineReady, "Prepare the engine in the app before running checks")
        let conversion = Task { await model.start() }
        try await Task.sleep(nanoseconds: 150_000_000)
        model.cancel()
        await conversion.value
        precondition(model.jobs[0].state == .cancelled && !model.isBusy)
        print("PASS real conversion cancellation updates queue")
        model.retry(model.jobs[0].id)
        await model.start()
        precondition(model.jobs[0].state == .done && model.markdown.contains("Docling Mac 验收文档"))
        precondition(model.html.contains("保留段落结构") && !model.isBusy)
        model.cleanup()
        print("PASS retry converts and loads real previews")
    }
}
