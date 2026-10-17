import Foundation

/// One app-wide preference; system dialogs and app strings change together on next launch.
enum AppLanguage: String, CaseIterable {
    case system, english = "en", simplifiedChinese = "zh-Hans"

    static let preferenceKey = "appLanguage"

    static func resolve(_ choice: AppLanguage, preferences: [String]) -> String {
        if choice != .system { return choice.rawValue }
        return Bundle.preferredLocalizations(from: ["en", "zh-Hans"], forPreferences: preferences).first ?? "en"
    }

    static func save(_ choice: AppLanguage, defaults: UserDefaults = .standard) {
        defaults.set(choice.rawValue, forKey: preferenceKey)
        // Let AppKit choose the same language for standard menus and file dialogs on launch.
        if choice == .system { defaults.removeObject(forKey: "AppleLanguages") }
        else { defaults.set([choice.rawValue], forKey: "AppleLanguages") }
    }
}

enum L10n {
    static let language = AppLanguage.resolve(
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: AppLanguage.preferenceKey) ?? "system") ?? .system,
        preferences: Locale.preferredLanguages)
    static let locale = Locale(identifier: language)
    private static let bundle: Bundle = {
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let localized = Bundle(path: path) else { return .main }
        return localized
    }()

    static func text(_ key: String, _ arguments: CVarArg...) -> String {
        format(key, arguments: arguments, bundle: bundle, locale: locale)
    }

    static func format(_ key: String, arguments: [CVarArg], bundle: Bundle, locale: Locale) -> String {
        let translated = bundle.localizedString(forKey: key, value: nil, table: nil)
        return arguments.isEmpty ? translated : String(format: translated, locale: locale, arguments: arguments)
    }
}
