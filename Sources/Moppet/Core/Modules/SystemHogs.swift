import Foundation

/// Read-only "space hog" reports the app deliberately never deletes:
/// iOS device backups, Mail and Messages attachments. These hold real user
/// data (TCC-protected in Mail/Messages' case), so the contract per the gap
/// analysis is: report the size, then hand the user to the tool that owns
/// the data (Finder for device backups, Mail/Messages settings for
/// attachments). The snapshot/Docker/Homebrew hogs are actionable and live
/// in their own engines.
enum SystemHogs {

    struct HogReport: Identifiable {
        enum Kind: String {
            case iosBackups, mail, messages
        }
        let kind: Kind
        let path: String
        let bytes: Int64
        let measurable: Bool
        /// True when the size is probably wrong because TCC blocked the walk.
        var needsFullDiskAccess: Bool { !measurable }

        var id: String { kind.rawValue }
    }

    static let iosBackupPath: String = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MobileSync/Backup").path
    static let mailPath: String = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mail").path
    static let messagesPath: String = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Messages").path

    // MARK: - Measurement

    /// Measures a TCC-protected tree. `contentsOfDirectory` on a denied
    /// folder throws — that maps to measurable=false instead of reporting
    /// a misleading "0 B".
    static func measure(_ path: String) -> (bytes: Int64, measurable: Bool) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return (0, false)
        }
        let summary = ScanEngine.size(of: URL(fileURLWithPath: path))
        // An unreadable directory yields 0 bytes AND 0 files; a readable
        // empty one would be unusual but possible — treat (0,0) as blocked.
        let readable = summary.files > 0 || summary.bytes > 0
        return (summary.bytes, readable)
    }

    static func reports() -> [HogReport] {
        var result: [HogReport] = []
        for (kind, path) in [(HogReport.Kind.iosBackups, iosBackupPath),
                             (.mail, mailPath), (.messages, messagesPath)] {
            let (bytes, measurable) = measure(path)
            result.append(HogReport(kind: kind, path: path, bytes: bytes, measurable: measurable))
        }
        return result
    }
}
