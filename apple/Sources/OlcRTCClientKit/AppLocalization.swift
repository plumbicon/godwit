import Foundation

private final class AppLocalizationBundleToken {}

public enum AppLocalization {
    public static var locale: Locale {
        Locale(identifier: localeIdentifier)
    }

    public static var localeIdentifier: String {
        Locale.current.region?.identifier == "RU" ? "ru_RU" : "en_US"
    }

    public static var timeLanguageCode: String {
        string("updated %@ ago").hasPrefix("обновлено") ? "ru" : "en"
    }

    public static func string(_ key: String) -> String {
        NSLocalizedString(key, bundle: localizationBundle, value: key, comment: "")
    }

    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key), locale: locale, arguments: arguments)
    }

    private static var localizationBundle: Bundle {
        let languageCode = localeIdentifier.hasPrefix("ru") ? "ru" : "en"

        guard let bundle = clientKitResourceBundle(),
              let path = bundle.path(forResource: languageCode, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return .main
        }
        return bundle
    }

    private static func clientKitResourceBundle() -> Bundle? {
        let bundleName = "OlcRTCApple_OlcRTCClientKit.bundle"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(bundleName),
            Bundle(for: AppLocalizationBundleToken.self).resourceURL?.appendingPathComponent(bundleName),
            Bundle.main.bundleURL.appendingPathComponent(bundleName),
        ]

        return candidates.lazy.compactMap { url in
            url.flatMap(Bundle.init(url:))
        }.first
    }
}
