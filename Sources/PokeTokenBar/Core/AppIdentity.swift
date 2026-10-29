import Foundation

/// 포크 앱의 식별값 — 원본 PokeTokenBar 설치본을 덮어쓰거나, 원본 업데이트를 받거나, 원본 세이브를
/// 같이 쓰지 않게 하는 단일 출처다. `scripts/build-app.sh` 가 같은 값을 Info.plist·LaunchAgent 에 쓰고,
/// `AppIdentityTests` 가 두 쪽이 어긋나거나 원본 값으로 되돌아가면 실패한다.
enum AppIdentity {
    static let bundleID = "io.github.dding94.poketokenbar-battle"
    static let appName = "PokeTokenBar Battle"
    /// 번들 안 실행 파일 이름. 원본(`PokeTokenBar`)과 달라야 `pkill -x` 가 원본 프로세스를 건드리지 않는다.
    static let executableName = "PokeTokenBarBattle"
    /// Application Support 아래 상태 폴더 이름. 원본 `PokeTokenBar` 폴더와 분리한다.
    static let stateDirectoryName = "PokeTokenBarBattle"
    static let loginAgentLabel = "io.github.dding94.poketokenbar-battle.login"
    static var loginAgentPlistName: String { loginAgentLabel + ".plist" }
    static let releaseRepo = "dding94/poketokenbar-battle"
    static var repositoryURL: String { "https://github.com/" + releaseRepo }
    static let caskName = "poke-token-bar-battle"
    /// 포크의 문제 리포트 수신처. 정해지기 전에는 nil 이고, 설정의 리포트 행을 숨긴다
    /// (원본 개발자 개인 메일로 포크 리포트가 가지 않게).
    static let supportEmail: String? = nil

    /// 포크가 다시 쓰면 안 되는 원본 값. 원본 세이브를 1회 복사해 올 때만 원본 경로를 읽는다.
    enum Upstream {
        static let bundleID = "io.github.chattymin.poketokenbar"
        static let appName = "PokeTokenBar"
        static let executableName = "PokeTokenBar"
        static let stateDirectoryName = "PokeTokenBar"
        static let loginAgentLabel = "io.github.chattymin.poketokenbar.login"
        static let releaseRepo = "chattymin/PokeTokenBar"
        static var repositoryURL: String { "https://github.com/" + releaseRepo }
        static let caskName = "poke-token-bar"
    }
}
