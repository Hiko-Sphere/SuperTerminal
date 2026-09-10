import Foundation

/// Which CloudKit database this build actually talks to.
///
/// Read back out of the built product rather than assumed from the build configuration,
/// because the two disagreed and nothing noticed (D-081). `com.apple.developer.icloud-container-environment`
/// decides whether a push reaches **Development**, where CloudKit creates a record type on
/// first write, or **Production**, where it does not and a type nobody deployed is refused
/// outright. The project's only documented device build is `-configuration Release`, Release
/// asks for Production, and the schema has never been deployed there — so every push from
/// every build that has ever been installed on a device was refused by the client's own
/// choice of database, and the refusal was written down as the container's own fault.
///
/// The entitlement itself cannot be read at runtime on iOS without a private API, so the
/// same build setting is carried into `Info.plist` and read from there. That is one step
/// removed from the entitlement, and a test asserts the two agree in the built product.
enum CloudKitEnvironment: String, Sendable {
    case development = "Development"
    case production = "Production"

    static let infoKey = "STCloudKitEnvironment"

    /// What this build declares, or nil if the key is missing or unrecognised — which is
    /// itself worth surfacing rather than defaulting to a guess.
    static func declared(in bundle: Bundle = .main) -> CloudKitEnvironment? {
        guard let raw = bundle.object(forInfoDictionaryKey: infoKey) as? String else { return nil }
        return CloudKitEnvironment(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The build configuration's own answer, from the compiler rather than from a plist.
    static var expected: CloudKitEnvironment {
        #if DEBUG
        .development
        #else
        .production
        #endif
    }

    var title: String {
        switch self {
        case .development: String(localized: "Development")
        case .production: String(localized: "Production")
        }
    }

    /// What a person looking at a sync that will not work needs to know, or nil when there
    /// is nothing to warn about.
    ///
    /// Production is right for a build going to the App Store and wrong for one being tested
    /// on a device before the schema is deployed — and the difference is invisible from
    /// inside the app unless it is said.
    var caution: String? {
        switch self {
        case .development:
            nil
        case .production:
            String(localized: "This build syncs with the Production iCloud database. A record type that has not been deployed there is refused, which looks exactly like iCloud being broken. Development builds should be built with the Debug configuration.")
        }
    }
}
