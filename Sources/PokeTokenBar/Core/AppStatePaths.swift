import Foundation

/// Application Support state directory for PokeTokenBar Battle files.
/// `PTB_STATE_DIR` overrides the default for development/QA isolation.
enum AppStatePaths {
    static func directory() -> URL {
        let dir = overrideDirectory()
            ?? defaultDirectory(applicationSupport: applicationSupportDirectory())
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `PTB_STATE_DIR` when set — a dev/QA run that must start from whatever that folder holds.
    static func overrideDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let override = (environment["PTB_STATE_DIR"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return override.isEmpty ? nil : URL(fileURLWithPath: override, isDirectory: true)
    }

    /// The fork's own folder. Never upstream's `PokeTokenBar`, which an installed upstream app keeps writing.
    static func defaultDirectory(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(AppIdentity.stateDirectoryName, isDirectory: true)
    }

    /// Upstream's folder. Only `UpstreamSaveImport` reads it, and never writes there.
    static func upstreamDirectory(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(AppIdentity.Upstream.stateDirectoryName, isDirectory: true)
    }

    static func applicationSupportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
}

/// 첫 실행에 원본 앱의 세이브를 **복사**해 온다. 원본 파일은 읽기만 하고, 포크 세이브가 이미 있으면
/// 아무것도 하지 않는다(재실행해도 포크 진행을 덮어쓰지 않는다). 세이브 파일 하나만 가져오고
/// 세션 키·캐시 같은 다른 파일은 원본 폴더에 그대로 둔다.
enum UpstreamSaveImport {
    enum Outcome: Equatable, Sendable {
        case imported
        case alreadyHasState
        case noUpstreamSave
        case failed(String)
    }

    static let fileName = "companion-state.json"

    static func runIfNeeded(from upstreamDirectory: URL, to forkDirectory: URL,
                            fileManager: FileManager = .default) -> Outcome {
        let target = forkDirectory.appendingPathComponent(fileName)
        guard !fileManager.fileExists(atPath: target.path) else { return .alreadyHasState }
        let source = upstreamDirectory.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: source.path) else { return .noUpstreamSave }
        do {
            try fileManager.createDirectory(at: forkDirectory, withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: target)
            return .imported
        } catch {
            return .failed(String(describing: error))
        }
    }
}
