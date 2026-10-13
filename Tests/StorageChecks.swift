import AppKit

@main
struct StorageChecks {
    @MainActor
    static func main() async throws {
        setbuf(stdout, nil)
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("Docling-storage-\(UUID().uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        func output(_ name: String) throws -> URL {
            let folder = directory.appendingPathComponent(name)
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("# Saved result\n".utf8).write(to: folder.appendingPathComponent("document.md"))
            try Data("<html><body>Saved result</body></html>".utf8).write(to: folder.appendingPathComponent("document.html"))
            try Data("""
            {
              "schema_name": "DoclingDocument",
              "version": "1.0.0",
              "name": "cached",
              "origin": {"filename": "cached.pdf"},
              "furniture": {}
            }
            """.utf8).write(to: folder.appendingPathComponent("document.json"))
            return folder
        }
        let cache = try output("cache-key")
        let root = directory.appendingPathComponent("Docling_Mac")
        let library = ResultLibrary(root: root)
        let first = directory.appendingPathComponent("a/报告.pdf")
        let second = directory.appendingPathComponent("b/报告.pdf")
        let folder = try await library.save(output: cache, source: first)
        let collision = try await library.save(output: cache, source: second)
        precondition(folder.lastPathComponent == "报告.pdf" && collision.lastPathComponent == "报告.pdf (2)")
        for item in [folder, collision] {
            precondition(["document.md", "document.html", "document.json"].allSatisfy { manager.fileExists(atPath: item.appendingPathComponent($0).path) })
        }
        let repeatFolder = try await library.save(output: cache, source: first)
        precondition(repeatFolder == folder)
        print("PASS automatic result directories keep same-name inputs separate and reuse identical conversions")

        let renamed = root.appendingPathComponent("手动分类")
        try manager.moveItem(at: folder, to: renamed)
        let reopened = ResultLibrary(root: root)
        let recovered = try await reopened.save(output: cache, source: first)
        precondition(recovered.resolvingSymlinksInPath().path == renamed.resolvingSymlinksInPath().path)
        let updated = try await reopened.save(output: output("new-cache-key"), source: first)
        precondition(updated != renamed && manager.fileExists(atPath: renamed.path))
        print("PASS relaunch finds Finder-renamed folders and changed results never overwrite old versions")

        try manager.removeItem(at: collision.appendingPathComponent("document.md"))
        let restored = try await reopened.save(output: cache, source: second)
        precondition(restored != collision && manager.fileExists(atPath: collision.path))
        let broken = try output("bad-cache")
        try Data("invalid".utf8).write(to: broken.appendingPathComponent("document.json"))
        var failed = false
        do { _ = try await reopened.save(output: broken, source: first) } catch { failed = true }
        let names = try manager.contentsOfDirectory(atPath: root.path)
        precondition(failed && !names.contains { $0.hasPrefix(".saving-") })
        print("PASS missing saved formats rebuild separately and failed writes publish no partial folder")

        let blockedRoot = directory.appendingPathComponent("blocked")
        try Data("occupied".utf8).write(to: blockedRoot)
        let model = AppModel(cacheURL: directory.appendingPathComponent("unused-cache"), resultsURL: blockedRoot)
        let source = directory.appendingPathComponent("sample.md")
        try Data("source".utf8).write(to: source)
        await model.add([source], startAutomatically: false)
        model.jobs[0].output = cache; model.jobs[0].state = .partial
        let id = model.jobs[0].id
        model.saveResult(id)
        while model.isSaving { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(model.jobs[0].savedOutput == nil && model.jobs[0].saveError != nil)
        let failedQuit = await model.shutdown()
        precondition(!failedQuit && manager.fileExists(atPath: cache.appendingPathComponent("document.md").path))
        try manager.removeItem(at: blockedRoot)
        model.saveResult(id)
        // Quit immediately: a completed partial conversion must finish saving first.
        let successfulQuit = await model.shutdown()
        precondition(successfulQuit)
        precondition(model.jobs[0].savedOutput != nil && model.jobs[0].saveError == nil && !model.isSaving)
        print("PASS unsaved results prevent quit; retry needs no conversion and successful quit drains saves")

        let large = try output("large")
        let limit = try RuntimeConfiguration.load(model.backend).previewMaxBytes
        precondition(limit == 100 * 1024 * 1024)
        func fill(_ url: URL, count: Int) throws {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            let chunk = Data(repeating: 65, count: 1024 * 1024)
            for _ in 0..<(count / chunk.count) { try handle.write(contentsOf: chunk) }
            try handle.write(contentsOf: chunk.prefix(count % chunk.count))
        }
        try fill(large.appendingPathComponent("document.html"), count: limit)
        do {
            let preview = try FileOperations.preview(large, maxBytes: limit, rendered: true)
            precondition(preview.0.isEmpty && preview.1.utf8.count == limit && !preview.2)
        }
        try fill(large.appendingPathComponent("document.html"), count: limit + 1)
        do {
            let preview = try FileOperations.preview(large, maxBytes: limit, rendered: true)
            precondition(preview.0.contains("Saved result") && preview.1.isEmpty && preview.2)
        }
        try fill(large.appendingPathComponent("document.md"), count: limit + 1)
        do {
            let preview = try FileOperations.preview(large, maxBytes: limit, rendered: false)
            precondition(preview.0.utf8.count == limit && preview.1.isEmpty && preview.2)
        }
        print("PASS exact 100 MiB previews, oversized HTML fallback, and bounded Markdown")

        let cancelled = Task.detached { try FileOperations.preview(large, maxBytes: limit, rendered: true) }
        cancelled.cancel()
        var stopped = false
        do { _ = try await cancelled.value } catch is CancellationError { stopped = true }
        precondition(stopped)
        print("PASS obsolete preview reads can be cancelled between chunks")

        let previewModel = AppModel(cacheURL: directory.appendingPathComponent("preview-cache"), resultsURL: root)
        let otherSource = directory.appendingPathComponent("other.md")
        try Data("other".utf8).write(to: otherSource)
        await previewModel.add([source, otherSource], startAutomatically: false)
        previewModel.jobs[0].output = large; previewModel.jobs[1].output = cache
        previewModel.selection = previewModel.jobs[0].id
        previewModel.loadPreview()
        try await Task.sleep(nanoseconds: 1_000_000)
        previewModel.selection = previewModel.jobs[1].id
        previewModel.loadPreview()
        for _ in 0..<500 where previewModel.previewLoading { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(previewModel.html.contains("Saved result") && previewModel.markdown.isEmpty && !previewModel.previewLimited)
        await previewModel.shutdown()
        print("PASS switching away from a large preview cannot replace the newly selected document")
    }
}
