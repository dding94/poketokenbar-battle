import XCTest
@testable import PokeTokenBar

/// 포크가 원본 PokeTokenBar 설치본·세이브·업데이트 채널과 섞이지 않는지 지키는 가드.
/// 원본 값으로 되돌리거나 build-app.sh 와 Swift 식별값이 어긋나면 실패한다(BATTLE_PLAN PR 00).
final class AppIdentityTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func script(_ name: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent("scripts/\(name)"), encoding: .utf8)
    }

    func testForkIdentityNeverReusesUpstreamValues() {
        XCTAssertNotEqual(AppIdentity.bundleID, AppIdentity.Upstream.bundleID)
        XCTAssertNotEqual(AppIdentity.appName, AppIdentity.Upstream.appName)
        XCTAssertNotEqual(AppIdentity.executableName, AppIdentity.Upstream.executableName)
        XCTAssertNotEqual(AppIdentity.stateDirectoryName, AppIdentity.Upstream.stateDirectoryName)
        XCTAssertNotEqual(AppIdentity.loginAgentLabel, AppIdentity.Upstream.loginAgentLabel)
        XCTAssertNotEqual(AppIdentity.releaseRepo, AppIdentity.Upstream.releaseRepo)
        XCTAssertNotEqual(AppIdentity.caskName, AppIdentity.Upstream.caskName)
        XCTAssertFalse(AppIdentity.loginAgentLabel.hasPrefix(AppIdentity.Upstream.bundleID))
    }

    func testLoginItemUsesForkAgent() {
        XCTAssertEqual(LoginItem.label, AppIdentity.loginAgentLabel)
        XCTAssertEqual(LoginItem.plistName, AppIdentity.loginAgentLabel + ".plist")
    }

    /// build-app.sh 가 쓰는 Info.plist·LaunchAgent 값이 Swift 식별값과 같아야 한다.
    /// 다르면 SMAppService 가 번들 안 plist 를 못 찾거나, 단일 인스턴스 판정이 원본 앱을 본다.
    func testBuildScriptMatchesSwiftIdentity() throws {
        let build = try script("build-app.sh")
        XCTAssertTrue(build.contains("APP_NAME=\"\(AppIdentity.appName)\""), "APP_NAME")
        XCTAssertTrue(build.contains("EXEC_NAME=\"\(AppIdentity.executableName)\""), "EXEC_NAME")
        XCTAssertTrue(build.contains("BUNDLE_ID=\"\(AppIdentity.bundleID)\""), "BUNDLE_ID")
        XCTAssertTrue(build.contains("LOGIN_LABEL=\"\(AppIdentity.loginAgentLabel)\""), "LOGIN_LABEL")
    }

    /// 원본 설치본을 지우던 경로(`rm -rf /Applications/PokeTokenBar.app`, `pkill -x PokeTokenBar`)로
    /// 돌아가지 않는다. 설치·종료 대상은 포크 이름 변수뿐이어야 한다.
    func testBuildScriptNeverTargetsUpstreamInstall() throws {
        let build = try script("build-app.sh")
        XCTAssertTrue(build.contains("pkill -x \"$EXEC_NAME\""))
        XCTAssertTrue(build.contains("rm -rf \"/Applications/$APP_NAME.app\""))
        XCTAssertFalse(build.contains("<string>\(AppIdentity.Upstream.bundleID)</string>"))
        XCTAssertFalse(build.contains("/Applications/PokeTokenBar.app"))
        XCTAssertFalse(build.contains("pkill -x \"$APP_NAME\""))
        XCTAssertTrue(build.contains("--entitlements \"$ENTITLEMENTS\""), "JSContext JIT entitlement")
    }

    func testReleaseScriptTargetsForkAndIsGated() throws {
        let release = try script("release.sh")
        XCTAssertTrue(release.contains("REPO=\"\(AppIdentity.releaseRepo)\""))
        XCTAssertTrue(release.contains("CASK_NAME=\"\(AppIdentity.caskName)\""))
        XCTAssertFalse(release.contains("REPO=\"\(AppIdentity.Upstream.releaseRepo)\""))
        XCTAssertFalse(release.contains("chattymin/homebrew-tap"))
        XCTAssertTrue(release.contains("PTB_FORK_RELEASE_READY"), "release must stay gated until verified")
    }

    func testUpdateCheckerUpgradesForkCaskOnly() {
        let upgrade = UpdateChecker.detachedUpgradeScript
        XCTAssertTrue(upgrade.contains("upgrade --cask \(AppIdentity.caskName)"))
        XCTAssertTrue(upgrade.contains(AppIdentity.loginAgentLabel))
        XCTAssertFalse(upgrade.contains("upgrade --cask \(AppIdentity.Upstream.caskName) "))
        XCTAssertFalse(upgrade.contains(AppIdentity.Upstream.loginAgentLabel))
    }

    func testSupportMailNeverDefaultsToUpstreamAuthor() {
        XCTAssertNotEqual(SupportMail.address, "parkdongmin123@gmail.com")
    }

    // MARK: 상태 폴더

    func testDefaultStateDirectoryIsForkFolder() {
        let support = URL(fileURLWithPath: "/tmp/ptb-support", isDirectory: true)
        let fork = AppStatePaths.defaultDirectory(applicationSupport: support)
        let upstream = AppStatePaths.upstreamDirectory(applicationSupport: support)
        XCTAssertEqual(fork.lastPathComponent, AppIdentity.stateDirectoryName)
        XCTAssertEqual(upstream.lastPathComponent, AppIdentity.Upstream.stateDirectoryName)
        XCTAssertNotEqual(fork.standardizedFileURL, upstream.standardizedFileURL)
    }

    func testStateDirectoryOverrideOnlyWhenSet() {
        XCTAssertNil(AppStatePaths.overrideDirectory(environment: [:]))
        XCTAssertNil(AppStatePaths.overrideDirectory(environment: ["PTB_STATE_DIR": "  "]))
        XCTAssertEqual(AppStatePaths.overrideDirectory(environment: ["PTB_STATE_DIR": "/tmp/qa"])?.path, "/tmp/qa")
    }

    // MARK: 원본 세이브 1회 복사

    private func makeDirs() throws -> (upstream: URL, fork: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpstreamSaveImport-\(UUID().uuidString)", isDirectory: true)
        let upstream = root.appendingPathComponent("PokeTokenBar", isDirectory: true)
        let fork = root.appendingPathComponent("PokeTokenBarBattle", isDirectory: true)
        try FileManager.default.createDirectory(at: upstream, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (upstream, fork)
    }

    func testImportCopiesUpstreamSaveAndLeavesSourceUntouched() throws {
        let (upstream, fork) = try makeDirs()
        let source = upstream.appendingPathComponent(UpstreamSaveImport.fileName)
        try Data("{\"dex\":[]}".utf8).write(to: source)
        let before = try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date

        XCTAssertEqual(UpstreamSaveImport.runIfNeeded(from: upstream, to: fork), .imported)

        let copied = fork.appendingPathComponent(UpstreamSaveImport.fileName)
        XCTAssertEqual(try Data(contentsOf: copied), try Data(contentsOf: source))
        let after = try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after, "the upstream save must only be read")
    }

    func testImportNeverOverwritesExistingForkSave() throws {
        let (upstream, fork) = try makeDirs()
        try Data("upstream".utf8).write(to: upstream.appendingPathComponent(UpstreamSaveImport.fileName))
        try FileManager.default.createDirectory(at: fork, withIntermediateDirectories: true)
        let forkSave = fork.appendingPathComponent(UpstreamSaveImport.fileName)
        try Data("fork progress".utf8).write(to: forkSave)

        XCTAssertEqual(UpstreamSaveImport.runIfNeeded(from: upstream, to: fork), .alreadyHasState)
        XCTAssertEqual(try String(contentsOf: forkSave, encoding: .utf8), "fork progress")
    }

    func testImportWithoutUpstreamSaveCreatesNothing() throws {
        let (upstream, fork) = try makeDirs()
        XCTAssertEqual(UpstreamSaveImport.runIfNeeded(from: upstream, to: fork), .noUpstreamSave)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fork.appendingPathComponent(UpstreamSaveImport.fileName).path))
    }
}
