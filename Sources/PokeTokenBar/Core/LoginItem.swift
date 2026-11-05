import ServiceManagement

/// 로그인 시 실행 + **크래시/비정상 종료 시 자동 재실행**(launchd KeepAlive).
///
/// 배경: `SMAppService.mainApp`(로그인아이템)은 **크래시 시 시스템이 재실행하지 않는다**(Apple 명시).
/// 그래서 KeepAlive 를 가진 LaunchAgent 로 대체한다 — launchd 가 워치독으로 동작해 앱이 비정상
/// 종료(크래시·OOM SIGKILL 등 exit≠0)되면 자동 재실행하고, **정상 종료(exit 0: 사용자 종료·업데이트)
/// 시엔 재실행하지 않는다**(`KeepAlive.SuccessfulExit=false`). ThrottleInterval 10s 로 폭주 방지.
///
/// plist 는 앱 번들 `Contents/Library/LaunchAgents/<plistName>` 에 있어야 한다(build-app.sh 가 생성).
/// 크래시-재실행은 launchd 가 프로세스를 소유해야 가능하므로, 로그인 실행도 이 에이전트가 담당한다
/// (= 로그인 실행과 크래시-재실행이 한 토글로 묶임 — 메뉴바 앱엔 자연스러운 결합).
@MainActor
enum LoginItem {
    static let plistName = AppIdentity.loginAgentPlistName
    static let label = AppIdentity.loginAgentLabel
    private static var agent: SMAppService { SMAppService.agent(plistName: plistName) }

    /// 현재 "로그인 시 실행(+크래시 자동 재실행)" 활성 여부.
    static var isEnabled: Bool { agent.status == .enabled }

    /// 토글 — 켜면 에이전트 등록(로그인 실행+KeepAlive), 끄면 해제. 실패 시 throw(호출부가 표면화).
    static func setEnabled(_ on: Bool) throws {
        if on {
            try agent.register()
            UserDefaults.standard.set(Bundle.main.bundlePath, forKey: registeredPathKey)
        } else {
            try agent.unregister()
        }
    }

    /// 구버전(`SMAppService.mainApp` 로그인아이템) → KeepAlive 에이전트로 **1회 이관**.
    /// 안전: mainApp 이 켜져 있을 때만 이관하고, **에이전트 등록이 성공한 뒤에만 mainApp 을 해제**한다
    /// (등록 실패 시 mainApp 을 유지 → 구동작 보존, "로그인 실행"을 잃지 않는다). 멱등(반복 호출 무해).
    static func migrateFromLegacyLoginItemIfNeeded() {
        let legacy = SMAppService.mainApp
        guard legacy.status == .enabled else { return }   // 구 로그인아이템 미사용 → 이관 불필요
        do {
            if agent.status != .enabled { try agent.register() }   // 에이전트 먼저 등록
            try legacy.unregister()                                 // 성공 후에만 구 항목 해제
            AppLog.write("login item migrated: mainApp → KeepAlive agent")
        } catch {
            AppLog.write("login item migration failed (mainApp 유지): \(error)")
        }
    }

    /// Outcome of the launch-time path check.
    enum PathCheck: Equatable { case notEnabled, upToDate, reregistered, failed }

    /// Pure decision: an enabled login agent must be re-registered when the bundle path recorded at
    /// registration time is missing (installs from before this check) or differs from the running bundle.
    static func needsReregistration(isEnabled: Bool, recordedPath: String?, currentPath: String) -> Bool {
        isEnabled && recordedPath != currentPath
    }

    /// Launch-time check with injectable side effects so the path comparison is testable without SMAppService.
    static func reconcileRegisteredPath(
        isEnabled: Bool, recordedPath: String?, currentPath: String,
        reregister: () throws -> Void, record: (String) -> Void
    ) -> PathCheck {
        guard isEnabled else { return .notEnabled }
        guard needsReregistration(isEnabled: isEnabled, recordedPath: recordedPath, currentPath: currentPath) else {
            return .upToDate
        }
        do {
            try reregister()
            record(currentPath)   // recorded only after success so a failure is retried next launch
            return .reregistered
        } catch {
            return .failed
        }
    }

    private static let registeredPathKey = "loginAgentRegisteredBundlePath"

    /// Called at launch. The agent plist's ProgramArguments is baked into the bundle, so an install moved
    /// from `/Applications/PokeTokenBar Battle.app` still has launchd pointing at the old path. Unregister
    /// and register again so launchd re-reads the plist of the running bundle.
    static func reconcileRegisteredPathAtLaunch() {
        let result = reconcileRegisteredPath(
            isEnabled: isEnabled,
            recordedPath: UserDefaults.standard.string(forKey: registeredPathKey),
            currentPath: Bundle.main.bundlePath,
            reregister: { try? agent.unregister(); try agent.register() },
            record: { UserDefaults.standard.set($0, forKey: registeredPathKey) })
        if result != .notEnabled && result != .upToDate { AppLog.write("login item path check: \(result)") }
    }
}
