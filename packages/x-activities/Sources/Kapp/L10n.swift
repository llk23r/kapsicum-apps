import Foundation

enum L10n {
    static func string(_ key: String, fallback: String? = nil) -> String {
        KapsicumRuntimeLocalization.bundle.localizedString(
            forKey: key,
            value: fallback ?? key,
            table: "XActivity")
    }

    static func format(
        _ key: String,
        fallback: String,
        _ arguments: CVarArg...
    ) -> String {
        String(
            format: string(key, fallback: fallback),
            locale: Locale.current,
            arguments: arguments)
    }
}
