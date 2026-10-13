import Foundation
import Darwin

struct ProcessResult {
    let status: Int32
    let output: String
    let errors: String
}

@MainActor
final class ProcessRunner {
    private var process: Process?
    private var grouped = false

    func run(_ executable: URL, arguments: [String], environment: [String: String] = [:],
             processGroup: Bool = false, update: @escaping (String, String) -> Void) async throws -> ProcessResult {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let out = folder.appendingPathComponent("stdout.log")
        let err = folder.appendingPathComponent("stderr.log")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        FileManager.default.createFile(atPath: err.path, contents: nil)
        let output = try FileHandle(forWritingTo: out)
        let errors = try FileHandle(forWritingTo: err)
        defer { try? output.close(); try? errors.close() }
        let child = Process()
        child.executableURL = executable
        child.arguments = arguments
        child.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        child.standardOutput = output
        child.standardError = errors
        child.standardInput = FileHandle.nullDevice
        try child.run()
        process = child
        grouped = processGroup
        let readLogs = {
            (Self.readTail(out), Self.readTail(err))
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { _ in
            let logs = readLogs()
            Task { @MainActor in update(logs.0, logs.1) }
        }
        defer { timer.invalidate(); process = nil }
        let status: Int32 = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                child.waitUntilExit()
                continuation.resume(returning: child.terminationStatus)
            }
        }
        let logs = readLogs()
        update(logs.0, logs.1)
        // Only the live log view is bounded; a completion event can contain many warnings.
        let protocolOutput = try String(contentsOf: out, encoding: .utf8)
        return ProcessResult(status: status, output: protocolOutput, errors: logs.1)
    }

    func cancel() {
        guard let process, process.isRunning else { return }
        if grouped && Darwin.kill(-process.processIdentifier, SIGTERM) == 0 { return }
        process.terminate()
    }

    nonisolated private static func readTail(_ url: URL) -> String {
        guard let file = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? file.close() }
        do {
            let size = try file.seekToEnd()
            try file.seek(toOffset: size > 32_768 ? size - 32_768 : 0)
            return String(decoding: try file.readToEnd() ?? Data(), as: UTF8.self)
        } catch { return "" }
    }
}
