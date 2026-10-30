// The one boundary for "who is calling" and "what may they touch".
// Worker side: turn the Authorization header into an access-key hash.
// League side: resolve that hash to an active trainer, enforce the role, and look up
// targets only inside the caller's own group (other groups read as not_found).

import { type Result, fail, ok } from "./contract";
import { ApiError } from "./http";
import { bearerKey, sha256Hex } from "./secrets";

/** SHA-256 of the bearer access key; unauthorized when the header is absent or malformed. */
export async function accessKeyHash(request: Request): Promise<string> {
  const key = bearerKey(request.headers.get("authorization"));
  if (key === null) throw new ApiError("unauthorized");
  return sha256Hex(key);
}

export type TrainerRow = {
  id: string;
  group_id: string;
  status: "active" | "left";
  display_email: string | null;
  joined_at: number;
};

export type InviteRow = {
  id: string;
  group_id: string;
  created_at: number;
  expires_at: number;
  max_uses: number;
  uses: number;
  revoked_at: number | null;
};

export const TRAINER_COLUMNS = "id, group_id, status, display_email, joined_at";
export const INVITE_COLUMNS = "id, group_id, created_at, expires_at, max_uses, uses, revoked_at";

export interface Actor {
  trainer: TrainerRow;
  groupId: string;
  isHost: boolean;
}

export type Permission = "member" | "host";

export interface TargetRules {
  /** Only active trainers count; a left one reads as not_found. */
  activeOnly: boolean;
}

export class GroupAccess {
  constructor(private readonly sql: SqlStorage) {}

  /** The active trainer holding this key, with at least `permission` in their group. */
  actor(keyHash: string, permission: Permission): Result<Actor> {
    const trainer = this.sql
      .exec<TrainerRow>(`SELECT ${TRAINER_COLUMNS} FROM trainers WHERE key_hash = ? AND status = 'active'`, keyHash)
      .toArray()[0];
    if (!trainer) return fail("unauthorized");
    const isHost = this.hostOf(trainer.group_id) === trainer.id;
    if (permission === "host" && !isHost) return fail("forbidden");
    return ok({ trainer, groupId: trainer.group_id, isHost });
  }

  /** Another trainer in the actor's group. Never the actor, never another group's trainer. */
  target(actor: Actor, trainerId: string, rules: TargetRules): Result<TrainerRow> {
    if (trainerId === actor.trainer.id) return fail("cannot_target_self");
    const target = this.trainerInGroup(trainerId, actor.groupId);
    if (!target || (rules.activeOnly && target.status !== "active")) return fail("not_found");
    return ok(target);
  }

  /** An invite of the actor's group. */
  invite(actor: Actor, inviteId: string): Result<InviteRow> {
    const invite = this.inviteInGroup(inviteId, actor.groupId);
    return invite ? ok(invite) : fail("not_found");
  }

  trainerInGroup(trainerId: string, groupId: string): TrainerRow | undefined {
    return this.sql
      .exec<TrainerRow>(`SELECT ${TRAINER_COLUMNS} FROM trainers WHERE id = ? AND group_id = ?`, trainerId, groupId)
      .toArray()[0];
  }

  inviteInGroup(inviteId: string, groupId: string): InviteRow | undefined {
    return this.sql
      .exec<InviteRow>(`SELECT ${INVITE_COLUMNS} FROM invites WHERE id = ? AND group_id = ?`, inviteId, groupId)
      .toArray()[0];
  }

  private hostOf(groupId: string): string | undefined {
    return this.sql.exec<{ host: string }>("SELECT host_trainer_id AS host FROM groups WHERE id = ?", groupId).toArray()[0]
      ?.host;
  }
}
