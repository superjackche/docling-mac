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
        let model = AppModel(cacheURL: directory.appendingPathComponent("cache"))
        await model.add([source, source, directory, URL(string: "https://example.com/file.pdf")!])
        precondition(model.jobs.count == 1 && model.errorMessage != nil)
        let alias = directory.appendingPathComponent("alias.pdf")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        model.errorMessage = nil
        await model.saveExport(from: source, to: alias)
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

        for parentExitsEarly in [false, true] {
        let familyRunner = ProcessRunner()
        var childReady = false
        var familyPID: Int32 = 0
        let familyScript = """
        import os, subprocess, sys, time
        subprocess.Popen([sys.executable, '-c', "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print('READY',flush=True); time.sleep(30)"])
        print('PARENT ' + str(os.getpid()), flush=True)
        time.sleep(\(parentExitsEarly ? "0.1" : "30"))
        """
        let family = Task {
            try await familyRunner.run(model.python, arguments: ["-u", "-c", familyScript], line: { value in
                if value == "READY" { childReady = true }
                if value.hasPrefix("PARENT ") { familyPID = Int32(value.dropFirst(7)) ?? 0 }
            }) { _, _ in }
        }
        for _ in 0..<200 where !childReady { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(childReady && familyPID > 0)
        if parentExitsEarly { try await Task.sleep(nanoseconds: 200_000_000) }
        familyRunner.cancel()
        _ = try await family.value
        for _ in 0..<100 where kill(-familyPID, 0) == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(kill(-familyPID, 0) != 0, "Cancelled descendants must not survive their parent")
        print(parentExitsEarly ? "PASS cancellation works after parent exit" : "PASS bounded shutdown kills a stubborn descendant")
        }

        await model.add([root.appendingPathComponent("Tests/fixtures/sample.html")])
        precondition(model.engineReady, "Prepare the engine in the app before running checks")
        let conversion = Task { await model.start() }
        try await Task.sleep(nanoseconds: 150_000_000)
        model.cancel()
        await conversion.value
        precondition(model.jobs[0].state == .cancelled && !model.isBusy)
        print("PASS real conversion cancellation updates queue")
        model.retry(model.jobs[0].id)
        await model.start()
        for _ in 0..<100 where model.markdown.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(model.jobs[0].state == .done && model.markdown.contains("Docling Mac 验收文档"))
        precondition(model.html.contains("保留段落结构") && !model.isBusy)
        await model.shutdown()
        print("PASS retry converts and loads real previews")

        let bigInput = directory.appendingPathComponent("many")
        try FileManager.default.createDirectory(at: bigInput, withIntermediateDirectories: true)
        for index in 0..<1000 {
            try Data("# Content \(index)".utf8).write(to: bigInput.appendingPathComponent("item-\(index).md"))
        }
        let bulk = AppModel(cacheURL: directory.appendingPathComponent("bulk-cache"))
        await bulk.add([bigInput])
        precondition(bulk.jobs.count == 1000)
        await bulk.add([bigInput])
        precondition(bulk.jobs.count == 1000, "Unchanged files must not be enqueued twice")
        try Data("# Changed content".utf8).write(to: bigInput.appendingPathComponent("item-0.md"))
        await bulk.add([bigInput.appendingPathComponent("item-0.md")])
        precondition(bulk.jobs.count == 1001, "Modified files must remain eligible")
        print("PASS 1000-file folder intake, deduplication and changed input")

        let a = directory.appendingPathComponent("a.md"), b = directory.appendingPathComponent("b.md")
        try Data("first".utf8).write(to: a); try Data("second".utf8).write(to: b)
        let report = try FileOperations.exportBatch([ExportFile(source: a, name: "Report.md"), ExportFile(source: b, name: "report.md")], to: directory)
        let names = try FileManager.default.contentsOfDirectory(at: report.directory, includingPropertiesForKeys: nil)
        precondition(report.count == 2 && report.errors.isEmpty && Set(names.map { $0.lastPathComponent.lowercased() }).count == 2)
        let contents = try Set(names.map { try String(contentsOf: $0, encoding: .utf8) })
        precondition(contents == ["first", "second"])
        print("PASS batch export keeps both same-name documents")

        let large = directory.appendingPathComponent("large-preview")
        try FileManager.default.createDirectory(at: large, withIntermediateDirectories: true)
        for name in ["document.md", "document.html"] { try Data(repeating: 65, count: 1_000_000).write(to: large.appendingPathComponent(name)) }
        let preview = try FileOperations.preview(large, maxBytes: 1024)
        precondition(preview.0.utf8.count == 1024 && preview.1.isEmpty && preview.2)
        print("PASS preview memory bound keeps full export on disk")
        await bulk.shutdown()

        let brokenBackend = directory.appendingPathComponent("broken-backend")
        try FileManager.default.copyItem(at: model.backend, to: brokenBackend)
        try Data("[invalid".utf8).write(to: brokenBackend.appendingPathComponent("pyproject.toml"))
        let isolatedSupport = directory.appendingPathComponent("isolated-support")
        try FileManager.default.createDirectory(at: isolatedSupport.appendingPathComponent("runtime/bin"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: isolatedSupport.appendingPathComponent("runtime/bin/python3"), withDestinationURL: model.python)
        try FileManager.default.copyItem(at: model.support.appendingPathComponent("engine.lock"),
                                        to: isolatedSupport.appendingPathComponent("engine.lock"))
        let repair = AppModel(backendURL: brokenBackend, cacheURL: directory.appendingPathComponent("repair-cache"), supportURL: isolatedSupport)
        precondition(repair.engineReady)
        await repair.install()
        precondition(!repair.engineReady && repair.errorMessage != nil)
        precondition(!FileManager.default.fileExists(atPath: isolatedSupport.appendingPathComponent("engine.lock").path))
        let reopened = AppModel(backendURL: brokenBackend, supportURL: isolatedSupport)
        precondition(!reopened.engineReady, "A failed repair cannot look ready after relaunch")
        print("PASS failed engine repair invalidates readiness across relaunch without touching the real runtime")
    }
}
