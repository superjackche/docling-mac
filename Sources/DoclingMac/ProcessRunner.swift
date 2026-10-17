import Foundation
import Darwin

struct ProcessResult {
    let status: Int32
    let output: String
    let errors: String
}

private enum ProcessChunk {
    case data(Data, stderr: Bool)
    case failure(String)
    case exit(Int32)
}

@MainActor
final class ProcessRunner {
    private var process: Process?
    private var ownedGroup: pid_t?
    private var forceStop: Task<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var isRunning: Bool { process != nil }

    func run(_ executable: URL, arguments: [String], environment: [String: String] = [:],
             processGroup: Bool = false, logLimit: Int = 32_768,
             line: @escaping (String) -> Void = { _ in },
             update: @escaping (String, String) -> Void) async throws -> ProcessResult {
        guard process == nil else { throw ClientError(L10n.text("已有后台任务正在运行。")) }
        let child = Process()
        let stdout = Pipe(), stderr = Pipe()
        child.executableURL = executable
        child.arguments = arguments
        child.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        child.standardOutput = stdout
        child.standardError = stderr
        child.standardInput = FileHandle.nullDevice
        child.qualityOfService = .utility
        try child.run()
        process = child
        let pid = child.processIdentifier
        ownedGroup = getpgid(pid) == pid ? pid : nil
        defer {
            forceStop?.cancel(); forceStop = nil; process = nil; ownedGroup = nil
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
        // Blocking pipe reads live off the UI thread; there is no idle polling timer.
        let stream = AsyncStream<ProcessChunk> { continuation in
            let readers = DispatchGroup()
            for (handle, isError) in [(stdout.fileHandleForReading, false), (stderr.fileHandleForReading, true)] {
                readers.enter()
                DispatchQueue.global(qos: .utility).async {
                    defer { try? handle.close(); readers.leave() }
                    var buffer = [UInt8](repeating: 0, count: 8192)
                    while true {
                        // POSIX read returns available pipe bytes immediately; Foundation's
                        // read(upToCount:) can wait for a full buffer and hide live progress.
                        let count = buffer.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
                        if count > 0 { continuation.yield(.data(Data(buffer.prefix(count)), stderr: isError)) }
                        else if count == 0 { break }
                        else if errno != EINTR {
                            continuation.yield(.failure(String(cString: strerror(errno))))
                            break
                        }
                    }
                }
            }
            readers.notify(queue: .global(qos: .utility)) {
                child.waitUntilExit()
                continuation.yield(.exit(child.terminationStatus))
                continuation.finish()
            }
        }
        var output = Data(), errors = Data(), pending = Data()
        var status: Int32 = -1
        var readError: String?
        for await chunk in stream {
            switch chunk {
            case .data(let data, let isError):
                if isError {
                    errors.append(data)
                    if errors.count > logLimit { errors = errors.suffix(logLimit) }
                } else {
                    output.append(data)
                    pending.append(data)
                    while let end = pending.firstIndex(of: 10) {
                        line(String(decoding: pending[..<end], as: UTF8.self))
                        pending.removeSubrange(...end)
                    }
                }
                update(String(decoding: output.suffix(logLimit), as: UTF8.self), String(decoding: errors, as: UTF8.self))
            case .failure(let message): readError = message; cancel()
            case .exit(let code): status = code
            }
        }
        // Finish the bounded group shutdown even if the parent exited before a child.
        if let forceStop { await forceStop.value }
        if !pending.isEmpty { line(String(decoding: pending, as: UTF8.self)) }
        if let readError { throw ClientError(L10n.text("无法读取后台进程输出：%@", String(describing: readError))) }
        return ProcessResult(status: status, output: String(decoding: output, as: UTF8.self),
                             errors: String(decoding: errors, as: UTF8.self))
    }

    func cancel() {
        guard let child = process else { return }
        let pid = child.processIdentifier
        // Foundation and the Python worker both give the child its own process group.
        let ownsGroup = ownedGroup == pid || getpgid(pid) == pid
        if ownsGroup { Darwin.kill(-pid, SIGTERM) }
        else if child.isRunning { child.terminate() }
        else { return }
        forceStop?.cancel()
        forceStop = Task {
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            if ownsGroup {
                if Darwin.kill(-pid, 0) == 0 { Darwin.kill(-pid, SIGKILL) }
            } else if child.isRunning { Darwin.kill(pid, SIGKILL) }
        }
    }

    func stopAndWait() async {
        guard process != nil else { return }
        cancel()
        await withCheckedContinuation { waiters.append($0) }
    }
}
