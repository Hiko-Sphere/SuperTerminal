import FileProvider
import Foundation
import STCore
import STSFTP

/// A failure that only the app can clear.
///
/// Kept separate from ``STError`` because it is not really an error about files: it is
/// the extension saying "this needs a person, and I am not where the person is". Files
/// turns it into the sign-in affordance on the domain.
public enum FileProviderFailure: Error, Equatable, Sendable {
    case needsTheApp(reason: String)
}

public enum FileProviderErrorMapping {
    /// Translates anything the SFTP stack can throw into the error Files understands.
    ///
    /// The mapping matters more than it looks. `noSuchItem` makes the system forget a
    /// file that is gone rather than showing it forever; `notAuthenticated` is what puts
    /// the "sign in" affordance on the domain instead of a dead end; `serverUnreachable`
    /// is what makes Files retry later instead of telling the user the file is broken.
    /// Returning a generic error for all of them would be the difference between a
    /// provider that recovers and one that has to be removed and re-added.
    public static func fileProviderError(from error: Error) -> Error {
        switch error {
        case let failure as FileProviderFailure:
            switch failure {
            case let .needsTheApp(reason):
                return NSError(
                    domain: NSFileProviderErrorDomain,
                    code: NSFileProviderError.notAuthenticated.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: reason]
                )
            }

        case let sftp as SFTPError:
            return fromSFTP(sftp)

        case let stError as STError:
            return fromST(stError)

        case is CancellationError:
            return NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)

        default:
            return error
        }
    }

    private static func fromSFTP(_ error: SFTPError) -> Error {
        switch error {
        case let .serverRefused(status, message):
            switch status {
            case .noSuchFile:
                return providerError(.noSuchItem, message)
            case .permissionDenied:
                // A Cocoa permission error, not `notAuthenticated`: the credential is
                // fine, this one file is not readable. Offering to sign in again would
                // send the user round a loop that cannot help.
                return NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFileWriteNoPermissionError,
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            case .operationUnsupported:
                return NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFeatureUnsupportedError,
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            case .noConnection, .connectionLost:
                return providerError(.serverUnreachable, message)
            default:
                return NSError(
                    domain: NSCocoaErrorDomain,
                    code: NSFileWriteUnknownError,
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            }
        case .channelClosed:
            return providerError(.serverUnreachable, String(
                localized: "The connection to the server closed.", bundle: .module
            ))
        case .cancelled:
            return NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        case let .unsupportedVersion(version):
            return providerError(.cannotSynchronize, String(
                localized: "The server speaks SFTP version \(version), which this app does not support.",
                bundle: .module
            ))
        case let .malformed(detail):
            return providerError(.cannotSynchronize, detail)
        }
    }

    private static func fromST(_ error: STError) -> Error {
        switch error.category {
        case .network, .tls, .tunnel:
            return providerError(.serverUnreachable, error.message)
        case .hostKey:
            // Deliberately `notAuthenticated`, with the reason spelled out: the host key
            // is unknown or has changed, and only the app can show the fingerprint and
            // ask. Silence here is how a changed key gets accepted by nobody noticing.
            return providerError(.notAuthenticated, error.message)
        case .sshAuthentication, .credential, .access:
            return providerError(.notAuthenticated, error.message)
        case .cancelled:
            return NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
        case .sshTransport, .sshChannel, .configuration, .internalError:
            return providerError(.cannotSynchronize, error.message)
        }
    }

    private static func providerError(_ code: NSFileProviderError.Code, _ message: String) -> Error {
        NSError(
            domain: NSFileProviderErrorDomain,
            code: code.rawValue,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
