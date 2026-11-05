import type { Battle } from "./battle-store";
export interface BattleEffect { recipients: string[]; groupId?: string; message: Record<string, unknown> }
export function battleChanged(b: Battle): BattleEffect { return { recipients: [b.p1, b.p2], message: { type: "battle_changed", battleId: b.battleId, state: b.state, revision: b.revision, roundSeq: b.roundSeq, deadline: b.state === "RUNNING" ? b.relay.current?.deadline ?? null : null } }; }
/**
 * D7: the first stored choice of a round tells the other seat, and only that seat, that a choice is in. It reuses the
 * existing battle_changed type with one more field, so a released app that ignores unknown keys sees an unchanged
 * notice. The slot, the choice text and the chooser never appear in it.
 */
export function choiceSubmitted(b: Battle, chooser: "p1" | "p2"): BattleEffect {
  const { message } = battleChanged(b);
  return { recipients: [chooser === "p1" ? b.p2 : b.p1], message: { ...message, opponentSubmitted: true } };
}
