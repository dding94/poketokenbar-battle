import Foundation

/// Presentation only. Consumes the engine's viewer-filtered log, never snapshots or report metadata.
/// Unknown protocol fields are deliberately omitted instead of echoing arbitrary payloads to the UI.
/// The words follow `l`; every other language reads the engine's own English names, so only Korean has dictionaries.
enum OnlineBattleHistoryText {
    static func logs(_ raw: [String], localSide: OnlineBattleSide, l: L) -> [String] {
        raw.compactMap { line($0, localSide: localSide, l: l) }
    }

    private static func line(_ raw: String, localSide: OnlineBattleSide, l: L) -> String? {
        let fields = raw.components(separatedBy: "|")
        guard fields.count >= 2, fields[0].isEmpty else { return nil }
        if fields[1] == "tie" { return l.online("무승부 · 배틀을 마쳤습니다.", "Draw · the battle is over.") }
        guard fields.count >= 3 else { return nil }
        let kind = fields[1], value = fields[2]
        let detail = fields.count > 3 ? fields[3] : ""
        if kind == "turn" {
            guard let turn = Int(value), (1...200).contains(turn) else { return nil }
            return l.online("── \(turn)턴 ──", "── Turn \(turn) ──")
        }
        if kind == "win", let side = OnlineBattleSide(rawValue: value) {
            let winner = actor(side, localSide, l: l)
            return l.online("\(winner) 승리 · 배틀을 마쳤습니다.", "\(winner) won · the battle is over.")
        }
        if kind == "-weather" {
            let known = ["RainDance": "비", "SunnyDay": "쾌청", "Sandstorm": "모래바람", "Hail": "싸라기눈", "Snow": "눈", "none": "종료"]
            let english = ["RainDance": "Rain", "SunnyDay": "Sun", "Sandstorm": "Sandstorm", "Hail": "Hail", "Snow": "Snow", "none": "ended"]
            let weather = (l.lang == .ko ? known : english)[value]
                ?? name(value, unknown: l.online("알 수 없는 날씨", "Unknown weather"), translations: [:])
            return l.online("날씨 · \(weather)", "Weather · \(weather)")
        }
        guard let side = side(value) else { return nil }
        let subject = actor(side, localSide, l: l)
        func moveName(_ value: String) -> String {
            name(value, unknown: l.online("알 수 없는 기술", "Unknown move"), translations: l.lang == .ko ? moves : [:])
        }
        func abilityName(_ value: String) -> String {
            name(value, unknown: l.online("알 수 없는 특성", "Unknown ability"), translations: l.lang == .ko ? abilities : [:])
        }
        switch kind {
        case "move":
            let move = moveName(detail)
            return l.online("\(subject) · \(move) 사용", "\(subject) · used \(move)")
        case "-ability":
            let ability = abilityName(detail)
            return l.online("\(subject) · 특성 \(ability) 공개", "\(subject) · ability \(ability) revealed")
        case "-damage", "-heal":
            guard let hp = health(detail) else { return nil }
            return kind == "-damage"
                ? l.online("\(subject) · 피해를 입었습니다 (HP \(hp)).", "\(subject) · took damage (HP \(hp)).")
                : l.online("\(subject) · 체력을 회복했습니다 (HP \(hp)).", "\(subject) · recovered HP (HP \(hp)).")
        case "switch", "drag": return l.online("\(subject) · 전투에 나왔습니다.", "\(subject) · entered the battle.")
        case "faint": return l.online("\(subject) · 쓰러졌습니다.", "\(subject) · fainted.")
        case "-miss": return l.online("\(subject) · 공격이 빗나갔습니다.", "\(subject) · missed.")
        case "-immune": return l.online("\(subject) · 효과가 없습니다.", "\(subject) · no effect.")
        case "-fail": return l.online("\(subject) · 기술이 실패했습니다.", "\(subject) · the move failed.")
        case "-status":
            let status = l.practiceStatusWord(detail)
            return l.online("\(subject) · \(status ?? "상태이상") 상태가 되었습니다.",
                            status.map { "\(subject) · is now \($0)." } ?? "\(subject) · has a new status.")
        case "-curestatus": return l.online("\(subject) · 상태이상이 회복됐습니다.", "\(subject) · status cured.")
        case "cant": return l.online("\(subject) · 행동할 수 없습니다.", "\(subject) · can't act.")
        case "-boost", "-unboost":
            let known = ["atk": "공격", "def": "방어", "spa": "특수공격", "spd": "특수방어", "spe": "스피드", "accuracy": "명중률", "evasion": "회피율"]
            let english = ["atk": "Attack", "def": "Defense", "spa": "Sp. Atk", "spd": "Sp. Def", "spe": "Speed", "accuracy": "Accuracy", "evasion": "Evasion"]
            let stat = (l.lang == .ko ? known : english)[detail] ?? l.online("능력치", "Stats")
            return kind == "-boost"
                ? l.online("\(subject) · \(stat) 상승", "\(subject) · \(stat) up")
                : l.online("\(subject) · \(stat) 하락", "\(subject) · \(stat) down")
        case "-supereffective": return l.online("효과가 굉장합니다!", "Super effective!")
        case "-resisted": return l.online("효과가 별로입니다.", "Not very effective.")
        case "-crit": return l.online("급소에 맞았습니다!", "Critical hit!")
        case "-start", "-end", "-activate", "-singleturn", "-singlemove":
            let effect: String
            if detail.hasPrefix("ability: ") {
                effect = abilityName(String(detail.dropFirst(9)))
            } else if detail.hasPrefix("move: ") {
                effect = moveName(String(detail.dropFirst(6)))
            } else {
                effect = name(detail, unknown: l.online("알 수 없는 효과", "Unknown effect"),
                              translations: l.lang == .ko ? ["confusion": "혼란", "substitute": "대타출동", "flinch": "풀죽음"] : [:])
            }
            return kind == "-end"
                ? l.online("\(subject) · \(effect) 종료", "\(subject) · \(effect) ended")
                : l.online("\(subject) · \(effect) 발동", "\(subject) · \(effect) activated")
        default: return kind.hasPrefix("-") ? l.online("전투 효과가 처리되었습니다.", "A battle effect took place.") : nil
        }
    }

    private static func side(_ value: String) -> OnlineBattleSide? {
        // Simulator names are not display names. Ignore their suffix completely.
        if value.hasPrefix("p1a: ") { return .p1 }
        if value.hasPrefix("p2a: ") { return .p2 }
        return nil
    }
    private static func actor(_ side: OnlineBattleSide, _ localSide: OnlineBattleSide, l: L) -> String {
        side == localSide ? l.online("내 포켓몬", "Your Pokémon") : l.online("상대 포켓몬", "Opposing Pokémon")
    }
    private static func name(_ value: String, unknown: String, translations: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -'.")
        guard !value.isEmpty, value.utf8.count <= 64, value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return unknown
        }
        let id = value.lowercased().filter { $0.isLetter || $0.isNumber }
        // A name outside the dictionary reads as itself (already limited to plain letters above), never as an apology.
        return translations[id] ?? value
    }
    private static func health(_ value: String) -> String? {
        // Already viewer-filtered: own HP is exact; the opponent's denominator is 100.
        guard value.range(of: #"^[0-9]{1,5}(/[0-9]{1,5})?( (par|brn|psn|tox|slp|frz|fnt))?$"#, options: .regularExpression) != nil else { return nil }
        return String(value.split(separator: " ")[0])
    }
    private static let moves = ["tackle": "몸통박치기", "quickattack": "전광석화", "splash": "튀어오르기", "thunderbolt": "10만볼트",
                                "protect": "방어", "recover": "HP회복", "struggle": "발버둥", "recharge": "반동", "imprison": "봉인",
                                "hyperbeam": "파괴광선", "earthquake": "지진", "surf": "파도타기", "flamethrower": "화염방사",
                                "icebeam": "냉동빔", "toxic": "맹독", "rest": "잠자기", "substitute": "대타출동"]
    private static let abilities = ["static": "정전기", "runaway": "도주", "adaptability": "적응력", "pressure": "프레셔",
                                    "intimidate": "위협", "levitate": "부유", "sturdy": "옹골참", "trace": "트레이스"]
}

/// Errors the online session sets directly on its presentation.
extension L {
    var onlineSettingsUnreadable: String {
        online("온라인 설정을 읽지 못했어요. 저장 폴더를 확인해 주세요.", "Couldn't read the online settings. Check the save folder.")
    }
    var onlineStandingsLoadFailed: String {
        online("그룹 전적을 불러오지 못했어요. 서버 지원 여부와 연결을 확인하고 다시 시도해 주세요.", "Couldn't load the group standings. Check your connection and that the server supports them, then try again.")
    }
    var onlineHistoryVoid: String { online("무효로 끝난 경기예요. 확정된 승패나 보상은 없어요.", "This battle ended as void. It has no confirmed result or reward.") }
    var onlineHistoryNotStarted: String { online("시작 전에 종료되어 다시보기 자료가 없어요.", "This battle ended before it started, so it has no replay data.") }
    var onlineReplayEngineMissing: String {
        online("이 경기의 전투 엔진이 앱에 없어 다시 볼 수 없어요. 경기 요약은 유지돼요.", "This app doesn't have the battle engine this battle used, so it can't be replayed. The summary stays.")
    }
    var onlineReplayRecordMissing: String {
        online("다시보기에 필요한 경기 자료가 없어요. 경기 요약은 유지돼요.", "The data needed for a replay is missing. The summary stays.")
    }
    var onlineReplayUnverified: String {
        online("기록을 검증하지 못해 다시보기를 열 수 없어요. 경기 결과는 바꾸지 않았어요.", "The record couldn't be verified, so the replay can't open. The battle result wasn't changed.")
    }
}
