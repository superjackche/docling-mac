import AppKit

// CI smoke test: constructing the real window exercises availability branches
// on both macOS 15 (native fallback) and macOS 26 (Liquid Glass).
let app = URL(fileURLWithPath: CommandLine.arguments[1])
let bundle = Bundle(url: app)!
precondition(bundle.object(forInfoDictionaryKey: "CFBundleDevelopmentRegion") as? String == "en")
for language in ["en", "zh-Hans"] {
    let path = bundle.path(forResource: language, ofType: "lproj")!
    let localized = Bundle(path: path)!
    let expected = language == "en" ? "Drop files or folders" : "拖入文件或文件夹"
    precondition(localized.localizedString(forKey: "拖入文件或文件夹", value: nil, table: nil) == expected,
                 "Missing packaged localization: \(language)")
}
print("PASS packaged English and Simplified Chinese localizations")
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
