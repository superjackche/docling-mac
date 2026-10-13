import Foundation
import Darwin

struct RuntimeConfiguration: Decodable {
    let cpuThreads: Int
    let pipelineBatchSize: Int
    let pipelineQueueSize: Int
    let cacheMaxBytes: Int
    let cacheMaxAgeDays: Int
    let previewMaxBytes: Int
    let logMaxBytes: Int
    let reuseNoticeSeconds: Double

    static func load(_ backend: URL) throws -> Self {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Self.self, from: Data(contentsOf: backend.appendingPathComponent("runtime.json")))
    }
}

struct InputFile: Sendable {
    let url: URL
    let revision: String
    var identity: String { url.path + "|" + revision }
}

struct ScanResult: Sendable {
    var files: [InputFile] = []
    var rejected: [String] = []
}

struct ExportFile: Sendable {
    let source: URL
    let name: String
    var originalFilename: String? = nil
}

struct ExportReport: Sendable {
    let directory: URL
    var count = 0
    var errors: [String] = []
}

enum FileOperations {
    static func scan(_ urls: [URL], extensions: Set<String>) -> ScanResult {
        var result = ScanResult()
        var seen = Set<String>()
        func append(_ url: URL, explicit: Bool) {
            guard extensions.contains(url.pathExtension.lowercased()) else {
                if explicit { result.rejected.append(url.lastPathComponent + "：不支持的格式") }
                return
            }
            do {
                let canonical = url.resolvingSymlinksInPath().standardizedFileURL
                let info = try canonical.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
                guard info.isRegularFile == true else { return }
                let item = InputFile(url: canonical, revision: "\(info.fileSize ?? 0):\(info.contentModificationDate?.timeIntervalSince1970 ?? 0)")
                if seen.insert(item.identity).inserted { result.files.append(item) }
            } catch { result.rejected.append(url.lastPathComponent + "：" + error.localizedDescription) }
        }
        for url in urls {
            guard !Task.isCancelled else { break }
            guard url.isFileURL else { result.rejected.append(url.absoluteString + "：仅支持本地文件"); continue }
            do {
                let info = try url.resourceValues(forKeys: [.isDirectoryKey])
                if info.isDirectory == true {
                    let iterator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) { item, error in
                        result.rejected.append(item.lastPathComponent + "：" + error.localizedDescription)
                        return true
                    }
                    guard let iterator else { result.rejected.append(url.lastPathComponent + "：无法读取文件夹"); continue }
                    for case let child as URL in iterator {
                        if Task.isCancelled { break }
                        append(child, explicit: false)
                    }
                } else { append(url, explicit: true) }
            } catch { result.rejected.append(url.lastPathComponent + "：" + error.localizedDescription) }
        }
        return result
    }

    static func preview(_ output: URL, maxBytes: Int) throws -> (String, String, Bool) {
        func read(_ name: String) throws -> (String, Bool) {
            let file = try FileHandle(forReadingFrom: output.appendingPathComponent(name))
            defer { try? file.close() }
            let data = try file.read(upToCount: maxBytes + 1) ?? Data()
            if data.count > maxBytes { return (String(decoding: data.prefix(maxBytes), as: UTF8.self), true) }
            return (String(decoding: data, as: UTF8.self), false)
        }
        let markdown = try read("document.md")
        let html = try read("document.html")
        // Do not feed a truncated HTML document (or huge base64 image) to WebKit.
        return (markdown.0, html.1 ? "" : html.0, markdown.1 || html.1)
    }

    static func save(_ source: URL, to destination: URL, protecting inputs: [URL], originalFilename: String? = nil) throws {
        let target = destination.resolvingSymlinksInPath().standardizedFileURL
        guard !inputs.contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL == target }) else {
            throw ClientError("请另存为新文件，避免覆盖输入文档。")
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".Docling-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try copyForExport(source, to: temporary, originalFilename: originalFilename)
        try Task.checkCancellation()
        guard rename(temporary.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private static func copyForExport(_ source: URL, to destination: URL, originalFilename: String?) throws {
        try Task.checkCancellation()
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        var initialData = Data()
        if source.pathExtension.lowercased() == "json", let originalFilename {
            let prefix = try input.read(upToCount: 64 * 1024) ?? Data()
            // The locked Docling exporter writes the complete source metadata before
            // this root field. JSON strings cannot contain an unescaped newline.
            let boundary = Data(",\n  \"furniture\":".utf8)
            guard let split = prefix.range(of: boundary) else {
                throw ClientError("Docling JSON 头部格式不符或超过 64 KiB，未导出文件。")
            }
            var headerData = Data(prefix[..<split.lowerBound])
            headerData.append(contentsOf: "\n}".utf8)
            guard var header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
                  header["schema_name"] as? String == "DoclingDocument",
                  header["version"] is String, header["name"] is String,
                  var origin = header["origin"] as? [String: Any], origin["filename"] is String else {
                throw ClientError("Docling JSON 缺少完整来源元数据，未导出文件。")
            }
            header["name"] = (originalFilename as NSString).deletingPathExtension
            origin["filename"] = originalFilename
            header["origin"] = origin
            var rewritten = try JSONSerialization.data(withJSONObject: header, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            rewritten.removeLast() // Leave the document's root object open for its untouched body.
            while let last = rewritten.last, [UInt8(9), 10, 13, 32].contains(last) { rewritten.removeLast() }
            initialData = rewritten
            initialData.append(prefix[split.lowerBound...])
        }

        // A batch export must never replace an existing file, even if filesystem
        // name normalization makes two generated names collide.
        let descriptor = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var complete = false
        defer {
            try? output.close()
            if !complete { try? FileManager.default.removeItem(at: destination) }
        }
        try output.write(contentsOf: initialData)
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: chunk)
        }
        try Task.checkCancellation()
        complete = true
    }

    static func exportBatch(_ files: [ExportFile], to parent: URL) throws -> ExportReport {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let folder = parent.appendingPathComponent("Docling-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(4))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        var report = ExportReport(directory: folder)
        var names = Set<String>()
        for file in files {
            if Task.isCancelled { report.errors.append("导出已停止"); break }
            let name = URL(fileURLWithPath: file.name)
            var candidate = file.name, suffix = 2
            while !names.insert(candidate.lowercased()).inserted {
                candidate = "\(name.deletingPathExtension().lastPathComponent) (\(suffix)).\(name.pathExtension)"
                suffix += 1
            }
            do {
                try copyForExport(file.source, to: folder.appendingPathComponent(candidate), originalFilename: file.originalFilename)
                report.count += 1
            } catch { report.errors.append(file.name + "：" + error.localizedDescription) }
        }
        return report
    }
}
