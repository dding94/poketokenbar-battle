import type { Side } from "./battle-input";
import type { Battle, BattleStore } from "./battle-store";
/** The only participant projection: private choices/reports never cross this boundary. */
export function battleView(store: BattleStore, b: Battle, viewer: string): unknown {
    const player = (side: Side) => {
      const s = b.snapshots[side]; if (!s) return { trainerId: b[side] };
      return b.config || viewer === b[side] ? { trainerId: b[side], snapshot: s } : { trainerId: b[side], public: s.public, hpPercent: s.hp / s.public.stats.hp * 100 };
    };
    const current = store.round(b, b.roundSeq), side: Side = viewer === b.p1 ? "p1" : "p2", other: Side = side === "p1" ? "p2" : "p1";
    // Only the fact that the other seat's choice is in, never its slot: the two views stay lockstep. It rides on this
    // projection alone; no WebSocket message carries it, so a released app that knows no new message type is unaffected.
    const opponentSubmitted = current?.pair === null && current[other] !== null;
    return { battleId: b.battleId, state: b.state, revision: b.revision, mode: b.mode, p1: player("p1"), p2: player("p2"), createdAt: b.createdAt, expiresAt: b.expiresAt, startedAt: b.startedAt, reportedAt: b.reportedAt, confirmed: b.confirmed, config: b.config, roundSeq: b.roundSeq, deadline: current?.pair === null ? current.deadline : null, ownChoice: current?.pair === null && current[side] !== null ? `move ${current[side]}` : null, journal: store.journal(b), result: b.result, reason: b.reason, rematchOf: b.rematchOf, opponentSubmitted };
  }
