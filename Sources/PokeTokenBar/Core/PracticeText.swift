import Foundation

/// Korean framing with the engine identifier retained when a translation is unavailable.
enum PracticeText {
    static func failure(_ error: Error) -> String {
        switch error {
        case BattleSnapshot.Failure.missingProfile: return "개체 정보가 아직 준비되지 않았습니다. 창을 닫고 잠시 후 다시 열어 주세요."
        case BattleSnapshot.Failure.missingNature: return "성격 정보가 없습니다."
        case BattleSnapshot.Failure.missingGender: return "성별 정보가 없습니다."
        case BattleSnapshot.Failure.missingAbility: return "특성 정보가 아직 없습니다."
        case BattleSnapshot.Failure.missingMoves: return "배운 기술 정보가 아직 없습니다."
        case BattleEngine.Failure.engine(let code):
            if code == "same_individual" { return "상대는 내 다른 개체를 골라 주세요." }
            return "전투를 진행할 수 없습니다 (\(code)). 개체 정보는 바꾸지 않았습니다."
        case BattleEngine.Failure.missingBundle: return "전투 엔진이 없습니다. 완성된 앱 번들로 실행해 주세요."
        case BattleEngine.Failure.checksumMismatch: return "전투 엔진 검증에 실패했습니다. 앱을 다시 빌드해 주세요."
        default: return "전투 정보를 확인할 수 없습니다. 창을 닫고 다시 시도해 주세요."
        }
    }
    static func log(_ line: String, names: [String: String]) -> String? {
        let p = line.components(separatedBy: "|")
        guard p.count > 2 else { return nil }
        let actor = names[String(p[2].prefix(2))] ?? p[2]
        let detail = p.count > 3 ? p[3] : ""
        switch p[1] {
        case "turn": return "── \(p[2])턴 ──"
        case "move": return "\(actor) · \(detail) 사용"
        case "-damage": return "\(actor) · 피해를 입었습니다 (HP \(detail))."
        case "-heal": return "\(actor) · 체력을 회복했습니다 (HP \(detail))."
        case "-miss": return "\(actor) · 공격이 빗나갔습니다."
        case "-immune": return "\(actor) · 효과가 없습니다."
        case "-fail": return "\(actor) · 기술이 실패했습니다."
        case "-status": return "\(actor) · \(status(detail)) 상태가 되었습니다."
        case "-curestatus": return "\(actor) · 상태이상이 회복됐습니다."
        case "cant": return "\(actor) · 행동할 수 없습니다 (\(detail))."
        case "-boost", "-unboost": return "\(actor) · 능력치 \(detail) \(p[1] == "-boost" ? "상승" : "하락")"
        case "-supereffective": return "효과가 굉장합니다!"
        case "-resisted": return "효과가 별로입니다."
        case "-crit": return "급소에 맞았습니다!"
        case "faint": return "\(actor) · 쓰러졌습니다."
        case "win": return "\(names[p[2]] ?? p[2]) 승리 · 연습전을 마쳤습니다."
        case "tie": return "무승부 · 연습전을 마쳤습니다."
        case "-weather": return "날씨 · \(p[2])"
        case "-start", "-end", "-activate": return "\(actor) · \(detail) \(p[1] == "-end" ? "종료" : "발동")"
        default:
            return p[1].hasPrefix("-") ? "전투 기록 · \(p.dropFirst(2).joined(separator: " · "))" : nil
        }
    }
    static func status(_ value: String) -> String {
        ["par": "마비", "brn": "화상", "psn": "독", "tox": "맹독", "slp": "잠듦", "frz": "얼음"][value] ?? value
    }
}
