import AppKit
import WebKit

/// WebKit otherwise consumes Finder drops before the parent SwiftUI view sees them.
final class FileDropWebView: WKWebView {
    var onFileDrop: ([URL]) -> Void = { _ in }
    var onTargetChanged: (Bool) -> Void = { _ in }
    private var acceptsFiles = false

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self],
                                options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptsFiles = sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                               options: [.urlReadingFileURLsOnly: true])
        onTargetChanged(acceptsFiles)
        return acceptsFiles ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptsFiles ? .copy : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        acceptsFiles
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { endTargeting() }
        let urls = Self.fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onFileDrop(urls)
        return true
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { endTargeting() }
    override func draggingEnded(_ sender: NSDraggingInfo) { endTargeting() }

    private func endTargeting() {
        acceptsFiles = false
        onTargetChanged(false)
    }
}
