import AppKit

@main
struct QueueFlowChecks {
    @MainActor
    static func main() async throws {
        setbuf(stdout, nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Docling-flow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(cacheURL: directory.appendingPathComponent("cache"))
        precondition(model.engineReady)
        func waitUntil(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(60)
            while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            if !condition() {
                let detail = "\(model.status); \(model.errorMessage ?? ""); \(model.logs)"
                await model.shutdown()
                preconditionFailure(detail)
            }
        }
        func source(_ name: String, text: String) throws -> URL {
            let url = directory.appendingPathComponent(name + ".html")
            try Data("<html><body><h1>\(text)</h1><p>Automatic queue.</p></body></html>".utf8).write(to: url)
            return url
        }
        let first = try source("first", text: "相同内容")
        let second = try source("second", text: "相同内容")
        await model.add([first, second])
        try await waitUntil { model.completed == 2 && !model.isBusy }
        let secondID = model.jobs[1].id
        precondition(model.jobs[1].cached)
        print("PASS intake automatically converts and duplicate content reuses results")

        await model.add([second])
        precondition(model.jobs.count == 2 && model.jobs[0].id == secondID && model.selection == secondID)
        precondition(model.showsReuseNotice(secondID))
        try await waitUntil { !model.showsReuseNotice(secondID) }
        precondition(model.jobs[0].state == .done && !model.isBusy)
        print("PASS repeated file moves to top, becomes selected, and its reuse notice expires")

        let third = try source("third", text: "Cancel this conversion")
        await model.add([third])
        let thirdID = model.jobs[0].id
        try await waitUntil { model.jobs.first(where: { $0.id == thirdID })?.state == .running }
        model.cancel()
        try await waitUntil { !model.isBusy }
        precondition(model.queuePaused && model.jobs.first(where: { $0.id == thirdID })?.state == .cancelled)
        let fourth = try source("fourth", text: "Continue only when requested")
        await model.add([fourth])
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(model.jobs[0].state == .pending && !model.isBusy && model.queuePaused)
        await model.start()
        precondition(model.jobs[0].state == .done && !model.queuePaused)
        print("PASS stop pauses automatic intake until explicit continuation")

        model.retry(thirdID)
        try await waitUntil { model.completed == 4 && !model.isBusy }
        print("PASS retry automatically starts the cancelled document")
        await model.shutdown()
    }
}
