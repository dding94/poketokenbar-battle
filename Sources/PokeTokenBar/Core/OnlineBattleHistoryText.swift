import Foundation

/// Presentation only. Consumes the engine's viewer-filtered log, never snapshots or report metadata.
/// Unknown protocol fields are deliberately omitted instead of echoing arbitrary payloads to the UI.
enum OnlineBattleHistoryText {
    static func logs(_ raw: [String], localSide: OnlineBattleSide) -> [String] {
        raw.compactMap { line($0, localSide: localSide) }
    }

    private static func line(_ raw: String, localSide: OnlineBattleSide) -> String? {
        let fields = raw.components(separatedBy: "|")
        guard fields.count >= 2, fields[0].isEmpty else { return nil }
        if fields[1] == "tie" { return "무승부 · 배틀을 마쳤습니다." }
        guard fields.count >= 3 else { return nil }
        let kind = fields[1], value = fields[2]
        let detail = fields.count > 3 ? fields[3] : ""
        if kind == "turn" {
            guard let turn = Int(value), (1...200).contains(turn) else { return nil }
            return "── \(turn)턴 ──"
        }
        if kind == "win", let side = OnlineBattleSide(rawValue: value) {
            return "\(actor(side, localSide)) 승리 · 배틀을 마쳤습니다."
        }
        if kind == "-weather" {
            let weather = ["RainDance": "비", "SunnyDay": "쾌청", "Sandstorm": "모래바람", "Hail": "싸라기눈", "Snow": "눈", "none": "종료"]
            return "날씨 · \(weather[value] ?? name(value, category: "날씨", translations: [:]))"
        }
        guard let side = side(value) else { return nil }
        let subject = actor(side, localSide)
        switch kind {
        case "move": return "\(subject) · \(name(detail, category: "기술", translations: moves)) 사용"
        case "-ability": return "\(subject) · 특성 \(name(detail, category: "특성", translations: abilities)) 공개"
        case "-damage", "-heal":
            guard let hp = health(detail) else { return nil }
            return "\(subject) · \(kind == "-damage" ? "피해를 입었습니다" : "체력을 회복했습니다") (HP \(hp))."
        case "switch", "drag": return "\(subject) · 전투에 나왔습니다."
        case "faint": return "\(subject) · 쓰러졌습니다."
        case "-miss": return "\(subject) · 공격이 빗나갔습니다."
        case "-immune": return "\(subject) · 효과가 없습니다."
        case "-fail": return "\(subject) · 기술이 실패했습니다."
        case "-status": return "\(subject) · \(statuses[detail] ?? "상태이상") 상태가 되었습니다."
        case "-curestatus": return "\(subject) · 상태이상이 회복됐습니다."
        case "cant": return "\(subject) · 행동할 수 없습니다."
        case "-boost", "-unboost":
            let stat = ["atk": "공격", "def": "방어", "spa": "특수공격", "spd": "특수방어", "spe": "스피드", "accuracy": "명중률", "evasion": "회피율"][detail] ?? "능력치"
            return "\(subject) · \(stat) \(kind == "-boost" ? "상승" : "하락")"
        case "-supereffective": return "효과가 굉장합니다!"
        case "-resisted": return "효과가 별로입니다."
        case "-crit": return "급소에 맞았습니다!"
        case "-start", "-end", "-activate", "-singleturn", "-singlemove":
            let effect: String
            if detail.hasPrefix("ability: ") {
                effect = name(String(detail.dropFirst(9)), category: "특성", translations: abilities)
            } else if detail.hasPrefix("move: ") {
                effect = name(String(detail.dropFirst(6)), category: "기술", translations: moves)
            } else {
                effect = name(detail, category: "효과", translations: ["confusion": "혼란", "substitute": "대타출동", "flinch": "풀죽음"])
            }
            return "\(subject) · \(effect) \(kind == "-end" ? "종료" : "발동")"
        default: return kind.hasPrefix("-") ? "전투 효과가 처리되었습니다." : nil
        }
    }

    private static func side(_ value: String) -> OnlineBattleSide? {
        // Simulator names are not display names. Ignore their suffix completely.
        if value.hasPrefix("p1a: ") { return .p1 }
        if value.hasPrefix("p2a: ") { return .p2 }
        return nil
    }
    private static func actor(_ side: OnlineBattleSide, _ localSide: OnlineBattleSide) -> String {
        side == localSide ? "내 포켓몬" : "상대 포켓몬"
    }
    private static func name(_ value: String, category: String, translations: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -'.")
        guard !value.isEmpty, value.utf8.count <= 64, value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return "알 수 없는 \(category)"
        }
        let id = value.lowercased().filter { $0.isLetter || $0.isNumber }
        return translations[id] ?? "미번역 \(category) (\(value))"
    }
    private static func health(_ value: String) -> String? {
        // Already viewer-filtered: own HP is exact; the opponent's denominator is 100.
        guard value.range(of: #"^[0-9]{1,5}(/[0-9]{1,5})?( (par|brn|psn|tox|slp|frz|fnt))?$"#, options: .regularExpression) != nil else { return nil }
        return String(value.split(separator: " ")[0])
    }
    private static let statuses = ["par": "마비", "brn": "화상", "psn": "독", "tox": "맹독", "slp": "잠듦", "frz": "얼음"]
    private static let moves = ["tackle": "몸통박치기", "quickattack": "전광석화", "splash": "튀어오르기", "thunderbolt": "10만볼트",
                                "protect": "방어", "recover": "HP회복", "struggle": "발버둥", "recharge": "반동", "imprison": "봉인",
                                "hyperbeam": "파괴광선", "earthquake": "지진", "surf": "파도타기", "flamethrower": "화염방사",
                                "icebeam": "냉동빔", "toxic": "맹독", "rest": "잠자기", "substitute": "대타출동"]
    private static let abilities = ["static": "정전기", "runaway": "도주", "adaptability": "적응력", "pressure": "프레셔",
                                    "intimidate": "위협", "levitate": "부유", "sturdy": "옹골참", "trace": "트레이스"]
}
