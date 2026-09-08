import Foundation
import Testing
@testable import ApexTerminal

/// The product is spelled with a space wherever a person reads it (D-038).
///
/// The rename to Apex Terminal missed the Face ID permission prompt — in English, in the
/// build settings, and in both Chinese catalogs — because that string lives in
/// `InfoPlist.xcstrings` and the localisation audit only walks the catalogs the compiler
/// emits keys for. A permission prompt is about as user-facing as a string gets. This is
/// the check that would have caught it.
@Suite struct ProductNameTests {
    private static let compact = "ApexTerminal"

    /// Every catalog that reaches a person, including the two the audit does not cover.
    private func catalogs() throws -> [(name: String, json: [String: Any])] {
        let bundle = Bundle(for: AppContainer.self)
        return try ["Localizable", "InfoPlist", "AppShortcuts"].compactMap { name in
            guard let url = bundle.url(forResource: name, withExtension: "xcstrings")
                ?? Bundle.main.url(forResource: name, withExtension: "xcstrings")
            else { return nil }
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
            return (name, json)
        }
    }

    @Test("No string a user reads spells the product without its space")
    func noCompactNameInUserFacingStrings() throws {
        // CFBundleName is the identifier form on purpose: it is the name on disk, not a
        // sentence. Everything else in these catalogs is read.
        let identifierKeys: Set<String> = ["CFBundleName"]
        for catalog in try catalogs() {
            let strings = catalog.json["strings"] as? [String: Any] ?? [:]
            for (key, entry) in strings where !identifierKeys.contains(key) {
                #expect(!key.contains(Self.compact), "\(catalog.name) key spells it compactly: \(key)")
                let localizations = (entry as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
                for (language, value) in localizations {
                    let unit = (value as? [String: Any])?["stringUnit"] as? [String: Any] ?? [:]
                    let text = unit["value"] as? String ?? ""
                    #expect(!text.contains(Self.compact),
                            "\(catalog.name)/\(language) spells it compactly: \(text.prefix(70))")
                }
            }
        }
    }
}
