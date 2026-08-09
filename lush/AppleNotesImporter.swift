#if os(macOS)
import AppKit

/// Pulls every note out of Apple Notes over Apple Events (needs the
/// com.apple.security.automation.apple-events entitlement and the user's
/// one-time consent) and converts the HTML bodies into span documents.
enum AppleNotesImporter {
    struct ImportedNote {
        let folder: String
        let name: String
        let modified: Date
        let html: String
    }

    static func fetchNotes() throws -> [ImportedNote] {
        let source = """
        set fieldSep to character id 31
        set noteSep to character id 30
        set out to ""
        tell application "Notes"
            repeat with f in folders
                set fName to name of f
                if fName is not "Recently Deleted" then
                    repeat with n in notes of f
                        try
                            set agoSecs to (current date) - (modification date of n)
                            set out to out & fName & fieldSep & (name of n) & fieldSep & agoSecs & fieldSep & (body of n) & noteSep
                        end try
                    end repeat
                end if
            end repeat
        end tell
        return out
        """
        guard let script = NSAppleScript(source: source) else {
            throw importError("couldn't build the Notes script")
        }
        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String
                ?? "Notes automation was refused"
            throw importError(message)
        }
        guard let raw = result.stringValue else { return [] }
        let now = Date()
        return raw
            .split(separator: "\u{1E}", omittingEmptySubsequences: true)
            .compactMap { chunk in
                let parts = chunk.split(
                    separator: "\u{1F}",
                    maxSplits: 3,
                    omittingEmptySubsequences: false
                )
                guard parts.count == 4 else { return nil }
                let ago = TimeInterval(parts[2]) ?? 0
                return ImportedNote(
                    folder: String(parts[0]),
                    name: String(parts[1]),
                    modified: now.addingTimeInterval(-ago),
                    html: String(parts[3])
                )
            }
    }

    private static func importError(_ message: String) -> NSError {
        NSError(
            domain: "AppleNotesImporter",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
#endif
