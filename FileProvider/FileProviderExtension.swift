import FileProvider
import OSLog
import STFileProvider

/// The extension's principal class, named in `Config/FileProviderInfo.plist`.
///
/// It forwards every call to `STFileProvider`, where the behaviour lives and where a test
/// can drive it against a real OpenSSH server; an extension class can only be driven by
/// the system inside an extension host, so anything written here would be untestable by
/// construction.
///
/// It forwards rather than inherits so that the conformance is declared by the very class
/// the Info.plist names, rather than by an ancestor. The system looks at this class to
/// decide which kind of provider it is dealing with, and Swift will not let a subclass
/// restate a conformance it inherits — so a subclass would leave that answer resting on
/// how the runtime treats inherited conformances. Ten lines of forwarding per method is a
/// cheap price for not having to know.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let core: SFTPFileProviderExtension

    required init(domain: NSFileProviderDomain) {
        // The first thing this process does, and the only evidence that it started at
        // all: an extension the system launches and immediately tears down leaves nothing
        // else behind.
        Logger(subsystem: "dev.apexterminal", category: "fileprovider")
            .notice("started for domain \(domain.identifier.rawValue, privacy: .public)")
        core = SFTPFileProviderExtension(domain: domain)
        super.init()
    }

    func invalidate() {
        core.invalidate()
    }

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        core.item(for: identifier, request: request, completionHandler: completionHandler)
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        core.fetchContents(
            for: itemIdentifier,
            version: requestedVersion,
            request: request,
            completionHandler: completionHandler
        )
    }

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        core.createItem(
            basedOn: itemTemplate,
            fields: fields,
            contents: url,
            options: options,
            request: request,
            completionHandler: completionHandler
        )
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        core.modifyItem(
            item,
            baseVersion: version,
            changedFields: changedFields,
            contents: newContents,
            options: options,
            request: request,
            completionHandler: completionHandler
        )
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        core.deleteItem(
            identifier: identifier,
            baseVersion: version,
            options: options,
            request: request,
            completionHandler: completionHandler
        )
    }

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        try core.enumerator(for: containerItemIdentifier, request: request)
    }
}
