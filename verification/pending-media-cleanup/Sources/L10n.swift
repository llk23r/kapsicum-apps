import Foundation

enum L10n {
    static func string(_ key: String, fallback: String? = nil) -> String {
        fallback ?? key
    }

    static func format(
        _ key: String,
        fallback: String,
        _ arguments: CVarArg...
    ) -> String {
        String(format: fallback, locale: Locale.current, arguments: arguments)
    }
}
