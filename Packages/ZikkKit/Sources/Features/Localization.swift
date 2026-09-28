import Foundation

/// Localized string from this module's string catalog.
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}
