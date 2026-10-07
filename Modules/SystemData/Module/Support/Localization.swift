import Foundation

/// The module's own bundle (`SystemData.macspacemodule`), which holds its translations: one `Localizable.strings` per language. In the
/// tests and the command-line tool it has none, and the English is used.
private var moduleBundle: Bundle { Bundle(for: SystemDataEntry.self) }

/// Text in the user's language. Interpolated values become the format's arguments (`"Free up to %@"`).
func loc(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: moduleBundle)
}

/// Text that comes from code shared with the helper (which has no translations), looked up by its English when it is shown.
func locKey(_ english: String) -> String {
    moduleBundle.localizedString(forKey: english, value: english, table: nil)
}
