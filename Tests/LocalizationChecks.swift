import Foundation

@main
struct LocalizationChecks {
    static func main() {
        precondition(AppLanguage.resolve(.system, preferences: ["en-GB", "zh-Hans-CN"]) == "en")
        precondition(AppLanguage.resolve(.system, preferences: ["zh-Hans-CN", "en-US"]) == "zh-Hans")
        precondition(AppLanguage.resolve(.system, preferences: ["fr-FR", "zh-Hans-CN", "en-US"]) == "zh-Hans")
        precondition(AppLanguage.resolve(.system, preferences: ["fr-FR"]) == "en")
        precondition(AppLanguage.resolve(.system, preferences: []) == "en")
        precondition(AppLanguage.resolve(.english, preferences: ["zh-Hans"]) == "en")
        precondition(AppLanguage.resolve(.simplifiedChinese, preferences: ["en"]) == "zh-Hans")
        print("PASS language negotiation and explicit overrides")

        let domain = "io.github.docling-mac.localization-checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        AppLanguage.save(.english, defaults: defaults)
        precondition(defaults.string(forKey: AppLanguage.preferenceKey) == "en")
        precondition(defaults.stringArray(forKey: "AppleLanguages") == ["en"])
        AppLanguage.save(.simplifiedChinese, defaults: defaults)
        precondition(defaults.stringArray(forKey: "AppleLanguages") == ["zh-Hans"])
        AppLanguage.save(.system, defaults: defaults)
        precondition(defaults.persistentDomain(forName: domain)?["AppleLanguages"] == nil)
        precondition(defaults.string(forKey: AppLanguage.preferenceKey) == "system")
        print("PASS persisted selection and removal of the app-specific system-language override")

        let resources = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/DoclingMac/Resources")
        var tables: [String: [String: String]] = [:]
        for language in ["en", "zh-Hans"] {
            let directory = resources.appendingPathComponent(language + ".lproj")
            let bundle = Bundle(url: directory)!
            let data = try! Data(contentsOf: directory.appendingPathComponent("Localizable.strings"))
            let table = try! PropertyListSerialization.propertyList(from: data, format: nil) as! [String: String]
            tables[language] = table
            let value = L10n.format("已添加 %@ 份", arguments: ["3"], bundle: bundle, locale: Locale(identifier: language))
            precondition(value == (language == "en" ? "Added: 3" : "已添加 3 份"))
            precondition(bundle.localizedString(forKey: "正在检查文件与缓存…", value: nil, table: nil)
                         == (language == "en" ? "Checking files and cache…" : "正在检查文件与缓存…"))
            for (key, value) in table {
                precondition(key.components(separatedBy: "%@").count == value.components(separatedBy: "%@").count,
                             "Placeholder mismatch: \(key)")
            }
        }
        precondition(Set(tables["en"]!.keys) == Set(tables["zh-Hans"]!.keys))
        print("PASS bilingual resources, interpolated counts, and worker messages")
    }
}
