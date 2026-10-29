import Foundation

/// Loads and keeps `PracticeRecords` at one file URL: the only practice code that writes to disk. The file sits in
/// the app's state folder next to the save but is never the save, so losing or resetting it changes nothing else.
/// The app passes `<state folder>/practice-records.json`; a nil URL keeps records in memory (tests, previews).
struct PracticeRecordStore: Sendable {
    let fileURL: URL?

    func load() -> PracticeRecords { PracticeRecords() }   // contract stub
    func persist(_ records: PracticeRecords) {}            // contract stub
}
