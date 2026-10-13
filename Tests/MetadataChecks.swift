import Foundation

@main
struct MetadataChecks {
    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Docling-metadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let cached = folder.appendingPathComponent("document.json")
        let python = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Docling Mac/runtime/bin/python3")
        let generate = Process()
        generate.executableURL = python
        generate.arguments = ["-c", """
from pathlib import Path
import sys
from docling_core.types.doc import DoclingDocument, DocItemLabel, DocumentOrigin
doc = DoclingDocument(name='private-original', origin=DocumentOrigin(
    filename='private-original.pdf', mimetype='application/pdf', binary_hash=13891688033632628532))
text = '正文 must not change. ' + ('Body literal {"name":"original","origin":{"filename":"inside-body.pdf"}}.\\n' * 60000)
doc.add_text(label=DocItemLabel.TEXT, text=text)
doc.save_as_json(Path(sys.argv[1]))
""", cached.path]
        try generate.run()
        generate.waitUntilExit()
        precondition(generate.terminationStatus == 0, "The actual installed Docling serializer must generate the fixture")
        let original = try Data(contentsOf: cached)
        precondition(original.count > 4 * 1024 * 1024)
        let boundary = Data(",\n  \"furniture\":".utf8)
        let originalBoundary = original.range(of: boundary)!
        let originalSuffix = original[originalBoundary.lowerBound...]
        let originalObject = try JSONSerialization.jsonObject(with: original) as! [String: Any]

        let filename = "中文报告 \"修订版\".pdf"
        let exported = folder.appendingPathComponent("中文导出.json")
        try FileOperations.save(cached, to: exported, protecting: [], originalFilename: filename)
        let rebound = try Data(contentsOf: exported)
        let object = try JSONSerialization.jsonObject(with: rebound) as! [String: Any]
        let origin = object["origin"] as! [String: Any]
        precondition(object["name"] as? String == "中文报告 \"修订版\"")
        precondition(origin["filename"] as? String == filename)
        precondition(origin["binary_hash"] as? NSNumber == (originalObject["origin"] as! [String: Any])["binary_hash"] as? NSNumber,
                     "Large unsigned origin hashes must retain their value")
        let reboundBoundary = rebound.range(of: boundary)!
        precondition(rebound[reboundBoundary.lowerBound...] == originalSuffix, "The entire body suffix must remain byte-identical")
        let cacheAfterSave = try Data(contentsOf: cached)
        precondition(cacheAfterSave == original, "Shared cached bytes must not change")
        print("PASS actual Docling JSON, Chinese filenames, large uint64, multi-megabyte untouched body, immutable cache")

        let markdown = folder.appendingPathComponent("document.md")
        let text = Data("# 原文\n正文 name origin.filename 不替换\n".utf8)
        try text.write(to: markdown)
        let markdownCopy = folder.appendingPathComponent("export.md")
        try FileOperations.save(markdown, to: markdownCopy, protecting: [], originalFilename: filename)
        let copiedMarkdown = try Data(contentsOf: markdownCopy)
        precondition(copiedMarkdown == text)
        print("PASS Markdown remains a direct byte-for-byte copy")

        let report = try FileOperations.exportBatch([
            ExportFile(source: cached, name: "同名.json", originalFilename: "甲.pdf"),
            ExportFile(source: cached, name: "同名.json", originalFilename: "乙.pdf")
        ], to: folder)
        precondition(report.count == 2 && report.errors.isEmpty)
        let first = try JSONSerialization.jsonObject(with: Data(contentsOf: report.directory.appendingPathComponent("同名.json"))) as! [String: Any]
        let second = try JSONSerialization.jsonObject(with: Data(contentsOf: report.directory.appendingPathComponent("同名 (2).json"))) as! [String: Any]
        precondition((first["origin"] as! [String: Any])["filename"] as? String == "甲.pdf")
        precondition((second["origin"] as! [String: Any])["filename"] as? String == "乙.pdf")
        let cacheAfterBatch = try Data(contentsOf: cached)
        precondition(cacheAfterBatch == original)
        print("PASS batch names do not overwrite and each JSON has its own input identity")

        let incompatible = folder.appendingPathComponent("incompatible.json")
        try Data("{\"name\":\"other schema\"}".utf8).write(to: incompatible)
        let protectedExport = folder.appendingPathComponent("existing.json")
        let keep = Data("existing export".utf8)
        try keep.write(to: protectedExport)
        var rejected = false
        do { try FileOperations.save(incompatible, to: protectedExport, protecting: [], originalFilename: filename) }
        catch { rejected = true }
        let retainedExport = try Data(contentsOf: protectedExport)
        precondition(rejected && retainedExport == keep)
        print("PASS unknown JSON boundary fails without replacing an existing export")

        let large = folder.appendingPathComponent("large.md")
        FileManager.default.createFile(atPath: large.path, contents: nil)
        let largeHandle = try FileHandle(forWritingTo: large)
        try largeHandle.truncate(atOffset: 512 * 1024 * 1024)
        try largeHandle.close()
        let cancelledDestination = folder.appendingPathComponent("cancelled.md")
        try keep.write(to: cancelledDestination)
        let copy = Task.detached {
            try FileOperations.save(large, to: cancelledDestination, protecting: [])
        }
        var observedCopy = false
        for _ in 0..<3000 {
            let paths = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
            if try paths.contains(where: {
                guard $0.lastPathComponent.hasPrefix(".Docling-export-") else { return false }
                return (try $0.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0
            }) { observedCopy = true; break }
            try await Task.sleep(for: .milliseconds(1))
        }
        copy.cancel()
        var cancelled = false
        do { try await copy.value } catch is CancellationError { cancelled = true }
        let preserved = try Data(contentsOf: cancelledDestination)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        precondition(observedCopy && cancelled && preserved == keep)
        precondition(!remaining.contains { $0.hasPrefix(".Docling-export-") })
        print("PASS active large export cancellation cleans partial output and preserves the existing destination")
    }
}
