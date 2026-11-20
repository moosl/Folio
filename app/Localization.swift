import Foundation

enum AppLanguage: String, CaseIterable {
    case system, english = "en", simplifiedChinese = "zh-Hans", traditionalChinese = "zh-Hant"
    case japanese = "ja", korean = "ko", french = "fr", german = "de", spanish = "es"
    case portuguese = "pt", italian = "it", russian = "ru"

    var menuTitle: String {
        switch self {
        case .system: return L("Follow System")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        case .traditionalChinese: return "繁體中文"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .spanish: return "Español"
        case .portuguese: return "Português"
        case .italian: return "Italiano"
        case .russian: return "Русский"
        }
    }

    static func resolve(_ choice: Self, preferred: [String]) -> Self {
        if choice != .system { return choice }
        for identifier in preferred {
            let language = Locale.Language(identifier:identifier)
            guard let code = language.languageCode?.identifier else { continue }
            if code == "zh" { return language.script?.identifier == "Hant" ? .traditionalChinese : .simplifiedChinese }
            if let match = AppLanguage(rawValue:code), match != .system { return match }
        }
        return .english
    }
}

enum Localization {
    // Use macOS's per-app override so AppKit and Sparkle also pick it up on launch.
    private static let key = "AppleLanguages"
    static var choice: AppLanguage {
        guard let id = Bundle.main.bundleIdentifier,
              let codes = UserDefaults.standard.persistentDomain(forName:id)?[key] as? [String],
              !codes.isEmpty else { return .system }
        return AppLanguage.resolve(.system,preferred:codes)
    }
    static func select(_ choice: AppLanguage) {
        if choice == .system { UserDefaults.standard.removeObject(forKey:key) }
        else { UserDefaults.standard.set([choice.rawValue],forKey:key) }
    }
    private(set) static var language = AppLanguage.english
    private(set) static var resources: Bundle?

    @discardableResult static func refresh() -> Bool {
        let preferred = UserDefaults.standard.stringArray(forKey:key) ?? Locale.preferredLanguages
        let next = AppLanguage.resolve(choice,preferred:preferred)
        guard resources == nil || next != language else { return false }
        language = next
        resources = Bundle.main.url(forResource:next.rawValue,withExtension:"lproj").flatMap(Bundle.init(url:))
        return true
    }
}

// English keys also provide a readable fallback for missing translations.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    let text = Localization.resources?.localizedString(forKey:key,value:key,table:nil) ?? key
    guard !arguments.isEmpty else { return text }
    return String(format:text,locale:Locale(identifier:Localization.language.rawValue),arguments:arguments)
}
