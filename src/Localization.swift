import Foundation

/// Small built-in localization layer. The UI follows the first preferred system language;
/// French is used for French systems and English is the fallback for everyone else.
func tr(_ french: String, _ english: String) -> String {
    let language = Locale.preferredLanguages.first?.lowercased() ?? "en"
    return language.hasPrefix("fr") ? french : english
}
