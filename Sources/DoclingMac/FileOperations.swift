import Foundation
import Darwin
import CryptoKit

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

enum FileOperations {
    static func scan(_ urls: [URL], extensions: Set<String>) -> ScanResult {
        var result = ScanResult()
        var seen = Set<String>()
        func append(_ url: URL, explicit: Bool) {
            guard extensions.contains(url.pathExtension.lowercased()) else {
                if explicit { result.rejected.append(url.lastPathComponent + L10n.text("：不支持的格式")) }
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
            guard url.isFileURL else { result.rejected.append(url.absoluteString + L10n.text("：仅支持本地文件")); continue }
            do {
                let info = try url.resourceValues(forKeys: [.isDirectoryKey])
                if info.isDirectory == true {
                    let iterator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) { item, error in
                        result.rejected.append(item.lastPathComponent + "：" + error.localizedDescription)
                        return true
                    }
                    guard let iterator else { result.rejected.append(url.lastPathComponent + L10n.text("：无法读取文件夹")); continue }
                    for case let child as URL in iterator {
                        if Task.isCancelled { break }
                        append(child, explicit: false)
                    }
                } else { append(url, explicit: true) }
            } catch { result.rejected.append(url.lastPathComponent + "：" + error.localizedDescription) }
        }
        return result
    }

    static func preview(_ output: URL, maxBytes: Int, rendered: Bool) throws -> (String, String, Bool) {
        func read(_ name: String) throws -> (String, Bool) {
            let file = try FileHandle(forReadingFrom: output.appendingPathComponent(name))
            defer { try? file.close() }
            var data = Data()
            while data.count <= maxBytes {
                try Task.checkCancellation()
                let chunk = try file.read(upToCount: min(1024 * 1024, maxBytes + 1 - data.count)) ?? Data()
                if chunk.isEmpty { break }
                data.append(chunk)
            }
            try Task.checkCancellation()
            if data.count > maxBytes { return (String(decoding: data.prefix(maxBytes), as: UTF8.self), true) }
            return (String(decoding: data, as: UTF8.self), false)
        }
        if rendered {
            let html = try read("document.html")
            if !html.1 { return ("", html.0, false) }
        }
        // Never feed truncated HTML or an incomplete base64 image to WebKit.
        let markdown = try read("document.md")
        return (markdown.0, "", rendered || markdown.1)
    }

    static func save(_ source: URL, to destination: URL, protecting inputs: [URL], originalFilename: String? = nil) throws {
        let target = destination.resolvingSymlinksInPath().standardizedFileURL
        guard !inputs.contains(where: { $0.resolvingSymlinksInPath().standardizedFileURL == target }) else {
            throw ClientError(L10n.text("请另存为新文件，避免覆盖输入文档。"))
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
                throw ClientError(L10n.text("Docling JSON 头部格式不符或超过 64 KiB，未保存文件。"))
            }
            var headerData = Data(prefix[..<split.lowerBound])
            headerData.append(contentsOf: "\n}".utf8)
            guard var header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
                  header["schema_name"] as? String == "DoclingDocument",
                  header["version"] is String, header["name"] is String,
                  var origin = header["origin"] as? [String: Any], origin["filename"] is String else {
                throw ClientError(L10n.text("Docling JSON 缺少完整来源元数据，未保存文件。"))
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

        // Never replace a file while streaming into a newly reserved destination.
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

}

// One actor serializes disk writes and indexes receipts once per app session.
// Receipts live with each result, so renaming a folder in Finder survives relaunch.
actor ResultLibrary {
    let root: URL
    private var folders: [String: URL]?
    private static let filenames = ["document.md", "document.html", "document.json"]
    private static let receiptName = ".docling-result.json"

    private struct Receipt: Codable {
        let identity: String
        let sizes: [String: Int]
    }

    init(root: URL) { self.root = root }

    func save(output: URL, source: URL) throws -> URL {
        let manager = FileManager.default
        try Task.checkCancellation()
        try manager.createDirectory(at: root, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        if folders == nil {
            var index: [String: URL] = [:]
            for folder in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: .skipsHiddenFiles) {
                let info = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard info.isDirectory == true, info.isSymbolicLink != true,
                      let data = try? Data(contentsOf: folder.appendingPathComponent(Self.receiptName)),
                      let receipt = try? JSONDecoder().decode(Receipt.self, from: data) else { continue }
                index[receipt.identity] = folder
            }
            folders = index
        }
        // Cache directory names include content, engine, model and conversion options.
        let identity = SHA256.hash(data: Data((source.path + "\n" + output.lastPathComponent).utf8))
            .map { String(format: "%02x", $0) }.joined()
        if let folder = folders?[identity],
           let data = try? Data(contentsOf: folder.appendingPathComponent(Self.receiptName)),
           let receipt = try? JSONDecoder().decode(Receipt.self, from: data), receipt.identity == identity,
           Self.filenames.allSatisfy({ name in
               let info = try? folder.appendingPathComponent(name).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
               return info?.isRegularFile == true && info?.isSymbolicLink != true && info?.fileSize == receipt.sizes[name]
           }) { return folder }

        // Build all formats privately, then publish the directory in one rename.
        let staging = root.appendingPathComponent(".saving-" + UUID().uuidString)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staging) }
        var sizes: [String: Int] = [:]
        for name in Self.filenames {
            try FileOperations.save(output.appendingPathComponent(name), to: staging.appendingPathComponent(name),
                                    protecting: [source], originalFilename: source.lastPathComponent)
            sizes[name] = try staging.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize
        }
        try JSONEncoder().encode(Receipt(identity: identity, sizes: sizes))
            .write(to: staging.appendingPathComponent(Self.receiptName), options: .atomic)
        var name = source.lastPathComponent
        while name.utf8.count > 220 { name.removeLast() }
        if name.hasPrefix(".") { name = "文档" + name }
        var suffix = 1
        while true {
            try Task.checkCancellation()
            let folder = root.appendingPathComponent(name + (suffix == 1 ? "" : " (\(suffix))"))
            // RENAME_EXCL also protects another app instance's result and user folders.
            if renamex_np(staging.path, folder.path, UInt32(RENAME_EXCL)) == 0 {
                folders?[identity] = folder
                return folder
            }
            guard errno == EEXIST else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            suffix += 1
        }
    }
}
