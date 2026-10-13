import AppKit
import WebKit

/// WebKit otherwise consumes Finder drops before the parent SwiftUI view sees them.
final class FileDropWebView: WKWebView {
    var onFileDrop: ([URL]) -> Void = { _ in }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self],
                                options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.fileURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !Self.fileURLs(from: sender.draggingPasteboard).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = Self.fileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onFileDrop(urls)
        return true
    }
}
