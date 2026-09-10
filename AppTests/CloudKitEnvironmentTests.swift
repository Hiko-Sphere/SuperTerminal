import Foundation
import Testing

@testable import ApexTerminal

/// Which CloudKit database this build actually talks to (D-081).
///
/// This suite exists because the answer was wrong for months and nothing anywhere read it
/// back. `com.apple.developer.icloud-container-environment` decides whether a push reaches
/// Development — where CloudKit creates a record type on first write — or Production, where
/// it does not and a type nobody has deployed is refused. The only device build the project
/// documented was `-configuration Release`, Release asks for Production, and the schema has
/// never been deployed there. So every push from every build ever installed on a device was
/// refused by this repository's own choice of database, and the refusal was written down as
/// the container's fault.
///
/// An entitlement nothing reads back is an assumption. These read it back.
@Suite("The CloudKit environment this build declares")
struct CloudKitEnvironmentTests {
    @Test("The built product carries the environment, and it is one of the two real ones")
    func declaredAtAll() throws {
        let raw = Bundle.main.object(forInfoDictionaryKey: CloudKitEnvironment.infoKey)
        let string = try #require(
            raw as? String,
            "Info.plist must carry \(CloudKitEnvironment.infoKey); without it the app cannot say which database it uses"
        )
        // Not left as the unexpanded build variable, which is what a mis-wired plist looks
        // like and which would read as "neither environment" rather than as a mistake.
        #expect(!string.contains("$("), "the build setting did not expand: \(string)")
        #expect(
            CloudKitEnvironment(rawValue: string) != nil,
            "\(string) is not a CloudKit environment"
        )
    }

    @Test("A Debug build talks to Development, not Production")
    func debugTalksToDevelopment() throws {
        let declared = try #require(CloudKitEnvironment.declared())
        // The tests run under Debug. If this build says Production, then the build that goes
        // onto a device says Production too, and every push is refused before the container
        // is even consulted — the exact failure that was recorded as H-5.
        #expect(
            declared == CloudKitEnvironment.expected,
            """
            this build declares \(declared.rawValue) but the configuration expects \
            \(CloudKitEnvironment.expected.rawValue). A build that talks to Production before \
            the schema is deployed there has every push refused, which reads as iCloud being \
            broken.
            """
        )
    }

    @Test("Production says what it costs; Development has nothing to warn about")
    func cautions() {
        #expect(CloudKitEnvironment.development.caution == nil)
        let caution = CloudKitEnvironment.production.caution
        #expect(caution != nil)
        // Names the thing to do, not just the state. A warning that does not say "build with
        // Debug" leaves the reader where they started.
        #expect(caution?.contains("Debug") == true)
    }

    @Test("An unknown or absent value is reported rather than guessed")
    func unknownIsNotAGuess() {
        #expect(CloudKitEnvironment(rawValue: "Staging") == nil)
        #expect(CloudKitEnvironment(rawValue: "") == nil)
        // Trimmed, because a plist value that came from a build setting can carry whitespace.
        #expect(CloudKitEnvironment(rawValue: "Development") == .development)
        #expect(CloudKitEnvironment(rawValue: "Production") == .production)
    }
}
