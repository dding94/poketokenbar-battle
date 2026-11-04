import Foundation

/// Presentation only. Consumes the engine's viewer-filtered log, never snapshots or report metadata.
enum OnlineBattleHistoryText {
    static func logs(_ raw: [String], localSide: OnlineBattleSide) -> [String] { [] }
}
