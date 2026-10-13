import AppKit

@main
struct DropChecks {
    @MainActor
    static func main() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let inputs = [URL(fileURLWithPath: "/tmp/中文 文档.pdf"), URL(fileURLWithPath: "/tmp/folder", isDirectory: true)]
        pasteboard.writeObjects(inputs as [NSURL])
        precondition(FileDropWebView.fileURLs(from: pasteboard) == inputs)
        print("PASS native multi-file/folder pasteboard preserves URLs and Chinese paths")
        pasteboard.clearContents()
        pasteboard.writeObjects([NSURL(string: "https://example.com/document.pdf")!])
        precondition(FileDropWebView.fileURLs(from: pasteboard).isEmpty)
        print("PASS preview rejects remote URL drops")
        pasteboard.clearContents()
        pasteboard.setString("/tmp/not-a-file-drop.pdf", forType: .string)
        precondition(FileDropWebView.fileURLs(from: pasteboard).isEmpty)
        print("PASS plain text cannot masquerade as a Finder file drop")
    }
}
