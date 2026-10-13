import AppKit

// CI smoke test: constructing the real window exercises availability branches
// on both macOS 15 (native fallback) and macOS 26 (Liquid Glass).
let app = URL(fileURLWithPath: CommandLine.arguments[1])
let process = Process()
process.executableURL = app.appendingPathComponent("Contents/MacOS/DoclingMac")
try process.run()
defer {
    if process.isRunning { process.terminate() }
    process.waitUntilExit()
}
Thread.sleep(forTimeInterval: 4)
guard process.isRunning else {
    fatalError("App exited before presenting its window: \(process.terminationStatus)")
}
let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as! [[String: Any]]
let mainWindow = windows.contains { window in
    guard window[kCGWindowOwnerPID as String] as? Int32 == process.processIdentifier,
          let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
    return frame.width >= 900 && frame.height >= 600
}
precondition(mainWindow, "The real SwiftUI main window was not created")
print("PASS native UI launches and presents its main window on \(ProcessInfo.processInfo.operatingSystemVersionString)")
