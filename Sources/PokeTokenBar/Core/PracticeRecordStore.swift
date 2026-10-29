import Foundation

/// Loads and keeps `PracticeRecords` at one file URL: the only practice code that writes to disk. The file sits in
/// the app's state folder next to the save but is never the save, so losing or resetting it changes nothing else.
/// The app passes `<state folder>/practice-records.json`; a nil URL keeps records in memory (tests, previews).
///
/// It never deletes. A file this version cannot read is moved aside before the records start over, and one that can
/// be neither read nor moved stays where it is: the folder refuses the atomic write that would replace it as well.
/// `PracticeReadOnlyGuardTests` allows this file the atomic write and the move, and nothing else that writes.
struct PracticeRecordStore: Sendable {
    let fileURL: URL?
    /// Names the copy of a file this version cannot read; tests pin it.
    var now: @Sendable () -> Date = { Date() }

    /// The records in the file: empty when there is none yet. A damaged file, or one written by a newer version, is
    /// renamed `<name>.corrupt-<UTC time>` (with `-2`, `-3`, … when taken) and the records start empty.
    func load() -> PracticeRecords {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return PracticeRecords() }
        if let data = try? Data(contentsOf: fileURL),
           let records = try? JSONDecoder().decode(PracticeRecords.self, from: data),
           records.version <= PracticeRecords.currentVersion {
            return records
        }
        keepAside(fileURL)
        return PracticeRecords()
    }

    /// Writes the records atomically, so an interrupted write never leaves half a file. A failure is logged and the
    /// records stay in memory; the next change tries again.
    func persist(_ records: PracticeRecords) {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try encoder.encode(records).write(to: fileURL, options: .atomic)
        } catch {
            AppLog.write("practice records not written: \(error)")
        }
    }

    private func keepAside(_ url: URL) {
        let stamp = now().formatted(Date.ISO8601FormatStyle(dateSeparator: .omitted, timeSeparator: .omitted))
        let base = url.path + ".corrupt-" + stamp
        var target = base, copy = 1
        while FileManager.default.fileExists(atPath: target) { copy += 1; target = "\(base)-\(copy)" }
        do {
            try FileManager.default.moveItem(atPath: url.path, toPath: target)
            AppLog.write("practice records unreadable, kept as \((target as NSString).lastPathComponent); starting over")
        } catch {
            AppLog.write("practice records unreadable and not moved aside, left in place: \(error)")
        }
    }
}
