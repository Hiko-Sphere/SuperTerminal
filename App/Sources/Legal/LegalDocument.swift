import Foundation

/// The documents the app ships and shows: three legal texts in the user's language,
/// and the third-party notices.
///
/// The texts are bundled Markdown, one file per language, chosen by the app's own
/// localisation rather than the system locale so the document matches the UI around it.
/// Licence texts are English only: they are the licences as granted.
enum LegalDocument: String, CaseIterable, Identifiable, Sendable {
    case terms
    case privacy
    case notice
    case licences

    var id: String { rawValue }

    /// Bumped whenever the Terms, Privacy Policy or User Notice change in substance.
    /// The consent screen shows again for anyone who accepted an older version.
    /// Bumped when the texts change in a way the user must see again: 2 removed every
    /// contact channel from all three languages; 3 added the assistant to the privacy
    /// policy, because it can send terminal text to a provider the user configures; 5
    /// removed the last address the Privacy Policy still asked people to write to, which
    /// version 2 had missed, and says instead that there is no request to make; 6 filled
    /// in the effective date and the developer's legal name, and removed the choice of
    /// governing law and venue — the terms now name no law and no court, which is a
    /// change to what the reader agreed to, not merely a blank being completed; 7 brought
    /// all three texts up to what the app now does — Secure Enclave keys, agent
    /// forwarding, port forwarding, the Files app, reused connections and the questions a
    /// server can ask — and replaced the iCloud sections, which described a switch this
    /// version does not offer, with what is actually true: nothing leaves the device; 8
    /// added Spotlight and Handoff, which are two ways the *system* can carry something
    /// outside the app — one of them off by default, both of them limited, and neither of
    /// them described before — and, in the same version, that a program on a server can
    /// ask to write this device's clipboard once the person allows it, while reading it is
    /// refused whatever they allow.
    static let currentVersion = 8

    var title: String {
        switch self {
        case .terms: String(localized: "Terms of Use")
        case .privacy: String(localized: "Privacy Policy")
        case .notice: String(localized: "User Notice")
        case .licences: String(localized: "Open-source licences")
        }
    }

    /// The language folder the app's UI is currently showing, reduced to the three the
    /// documents exist in.
    static var documentLanguage: String {
        let preferred = Bundle.main.preferredLocalizations.first ?? "en"
        if preferred.hasPrefix("zh-Hans") { return "zh-Hans" }
        if preferred.hasPrefix("zh-Hant") || preferred.hasPrefix("zh-HK") || preferred.hasPrefix("zh-TW") { return "zh-Hant" }
        return "en"
    }

    /// The document's Markdown. A missing resource is a packaging defect, and one the
    /// screen must say out loud rather than show an empty page.
    func markdown(bundle: Bundle = .main) throws -> String {
        let name: String
        switch self {
        case .licences: name = "THIRD_PARTY_NOTICES"
        default: name = "legal-\(rawValue)-\(Self.documentLanguage)"
        }
        guard let url = bundle.url(forResource: name, withExtension: "md") else {
            throw LegalDocumentError.missing(name)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

enum LegalDocumentError: Error, LocalizedError {
    case missing(String)

    var errorDescription: String? {
        switch self {
        case let .missing(name):
            String(localized: "The document \(name) is not included in this build.")
        }
    }
}
