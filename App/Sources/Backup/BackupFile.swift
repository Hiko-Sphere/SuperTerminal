import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// The app's own backup type, so Files.app shows the icon and the Share Sheet offers
    /// the right destinations (D-040). Declared as owned by the app in Info.plist.
    static let apexBackup = UTType(exportedAs: "dev.apexterminal.backup", conformingTo: .json)
}

/// The document `fileExporter` writes. It carries bytes that are already encoded, so the
/// export cannot fail at the moment the user picks a folder.
struct BackupFile: FileDocument {
    static let readableContentTypes: [UTType] = [.apexBackup, .json]

    let data: Data

    init(document: BackupDocument) {
        data = (try? BackupService.encoder.encode(document)) ?? Data()
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }

    /// Dated, because the first thing anyone wants to know about a backup is when it was
    /// taken, and the second is whether it is the newest one.
    static func defaultFilename(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "Apex Terminal \(formatter.string(from: now))"
    }
}
