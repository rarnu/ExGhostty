import Foundation
import GhosttyKit

/// Returns the localized version of the string using Ghostty's gettext domain.
///
/// `ghostty_translate` is exported by libghostty and will return the `msgid`
/// unchanged when no translation is available, so English strings used as
/// message IDs remain the built-in default language.
func L(_ key: String) -> String {
    return key.withCString { ptr in
        guard let translated = ghostty_translate(ptr) else { return key }
        return String(cString: translated)
    }
}

/// Localizes a format string and substitutes the given arguments.
func L(_ format: String, _ args: CVarArg...) -> String {
    return String(format: L(format), arguments: args)
}

extension String {
    /// Localizes the receiver through Ghostty's gettext domain.
    var localized: String {
        return L(self)
    }
}
