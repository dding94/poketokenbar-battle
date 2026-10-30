import { DurableObject } from "cloudflare:workers";
import { GroupAccess, INVITE_COLUMNS, type InviteRow, TRAINER_COLUMNS, type TrainerRow } from "./access";
import {
  type AccountGrant,
  type AttemptKind,
  type AuditEntry,
  type AuditKind,
  type Fail,
  type GroupView,
  type InviteView,
  type MemberView,
  type Result,
  type TrainerView,
  fail,
  ok,
} from "./contract";

// The League never sees a raw key or code: every *Hash argument is computed by the Worker.

export const SCHEMA_VERSION = 1;
const MINUTE = 60_000;
const DAY = 24 * 60 * MINUTE;
export const ATTEMPT_LIMIT = 10;
export const ATTEMPT_WINDOW_MS = 15 * MINUTE;
export const ATTEMPT_RETENTION_MS = DAY;
export const RECONNECT_TTL_MS = DAY;
const AUDIT_PAGE = 200;

const SCHEMA_V1 = [
  `CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)`,
  `CREATE TABLE groups (
     id TEXT PRIMARY KEY,
     name TEXT NOT NULL,
     host_trainer_id TEXT NOT NULL,
     created_at INTEGER NOT NULL
   )`,
  `CREATE TABLE trainers (
     id TEXT PRIMARY KEY,
     group_id TEXT NOT NULL,
     status TEXT NOT NULL CHECK (status IN ('active', 'left')),
     display_email TEXT,
     email_norm TEXT,
     key_hash TEXT UNIQUE,
     recovery_hash TEXT UNIQUE,
     joined_at INTEGER NOT NULL,
     left_at INTEGER,
     CHECK ((status = 'active' AND display_email IS NOT NULL AND email_norm IS NOT NULL AND key_hash IS NOT NULL)
         OR (status = 'left' AND display_email IS NULL AND email_norm IS NULL AND key_hash IS NULL))
   )`,
  `CREATE INDEX trainers_group ON trainers (group_id)`,
  `CREATE UNIQUE INDEX trainers_group_email ON trainers (group_id, email_norm) WHERE email_norm IS NOT NULL`,
  `CREATE TABLE invites (
     id TEXT PRIMARY KEY,
     group_id TEXT NOT NULL,
     code_hash TEXT NOT NULL UNIQUE,
     created_by TEXT NOT NULL,
     created_at INTEGER NOT NULL,
     expires_at INTEGER NOT NULL,
     max_uses INTEGER NOT NULL,
     uses INTEGER NOT NULL DEFAULT 0,
     revoked_at INTEGER
   )`,
  `CREATE INDEX invites_group ON invites (group_id)`,
  `CREATE TABLE reconnect_codes (
     id TEXT PRIMARY KEY,
     group_id TEXT NOT NULL,
     trainer_id TEXT NOT NULL,
     code_hash TEXT NOT NULL UNIQUE,
     created_by TEXT NOT NULL,
     created_at INTEGER NOT NULL,
     expires_at INTEGER NOT NULL,
     used_at INTEGER,
     voided_at INTEGER
   )`,
  `CREATE INDEX reconnect_codes_trainer ON reconnect_codes (trainer_id)`,
  `CREATE TABLE audit (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     group_id TEXT NOT NULL,
     at INTEGER NOT NULL,
     kind TEXT NOT NULL,
     actor_id TEXT,
     target_id TEXT,
     invite_id TEXT
   )`,
  `CREATE INDEX audit_group ON audit (group_id, id)`,
  `CREATE TABLE attempts (ip_hash TEXT NOT NULL, kind TEXT NOT NULL, at INTEGER NOT NULL)`,
  `CREATE INDEX attempts_lookup ON attempts (ip_hash, kind, at)`,
  `CREATE INDEX attempts_at ON attempts (at)`,
];

type GroupRow = { id: string; name: string; host_trainer_id: string };

type ReconnectRow = {
  id: string;
  group_id: string;
  trainer_id: string;
  expires_at: number;
  used_at: number | null;
  voided_at: number | null;
};

type AuditRow = {
  id: number;
  at: number;
  kind: AuditKind;
  actor_id: string | null;
  target_id: string | null;
  invite_id: string | null;
};

function newId(prefix: string): string {
  return `${prefix}_${crypto.randomUUID().replaceAll("-", "")}`;
}

export interface NewCredentials {
  keyHash: string;
  recoveryHash: string;
}

export interface Email {
  display: string;
  norm: string;
}

export class League extends DurableObject<Env> {
  /** Single clock for every time check. Tests replace it through runInDurableObject. */
  clock: () => number = () => Date.now();

  private readonly sql: SqlStorage;
  private readonly access: GroupAccess;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;
    this.access = new GroupAccess(this.sql);
    this.migrate();
  }

  // ---- schema ----

  private migrate(): void {
    const hasMeta = this.sql.exec("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'meta'").toArray();
    let version = 0;
    if (hasMeta.length > 0) {
      const row = this.sql.exec<{ value: string }>("SELECT value FROM meta WHERE key = 'schema_version'").toArray()[0];
      version = row ? Number(row.value) : 0;
    }
    if (version >= SCHEMA_VERSION) return;
    this.ctx.storage.transactionSync(() => {
      if (version < 1) for (const statement of SCHEMA_V1) this.sql.exec(statement);
      this.sql.exec(
        "INSERT INTO meta (key, value) VALUES ('schema_version', ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
        String(SCHEMA_VERSION),
      );
    });
  }

  // ---- RPC: credential-less entry points ----

  createGroup(input: {
    ipHash: string;
    operatorOk: boolean;
    groupName: string;
    email: Email;
    credentials: NewCredentials;
  }): Result<AccountGrant> {
    const now = this.clock();
    return this.tx(() => {
      const limited = this.checkAttempts(input.ipHash, "operator", now);
      if (limited) return limited;
      if (!input.operatorOk) return this.failAttempt(input.ipHash, "operator", now, "operator_denied");

      const groupId = newId("gr");
      const trainerId = newId("tr");
      this.sql.exec(
        "INSERT INTO groups (id, name, host_trainer_id, created_at) VALUES (?, ?, ?, ?)",
        groupId,
        input.groupName,
        trainerId,
        now,
      );
      this.insertTrainer(trainerId, groupId, input.email, input.credentials, now);
      return ok(this.grant(trainerId));
    });
  }

  join(input: { ipHash: string; inviteHash: string | null; email: Email; credentials: NewCredentials }): Result<AccountGrant> {
    const now = this.clock();
    return this.tx(() => {
      const limited = this.checkAttempts(input.ipHash, "invite", now);
      if (limited) return limited;
      const invite =
        input.inviteHash === null
          ? undefined
          : this.sql
              .exec<InviteRow>(
                `SELECT ${INVITE_COLUMNS} FROM invites WHERE code_hash = ?`,
                input.inviteHash,
              )
              .toArray()[0];
      if (!invite) return this.failAttempt(input.ipHash, "invite", now, "invalid_invite");
      if (invite.revoked_at !== null) return this.failAttempt(input.ipHash, "invite", now, "invite_revoked");
      if (now >= invite.expires_at) return this.failAttempt(input.ipHash, "invite", now, "invite_expired");
      if (invite.uses >= invite.max_uses) return this.failAttempt(input.ipHash, "invite", now, "invite_used_up");
      if (this.emailTaken(invite.group_id, input.email.norm)) return fail("display_email_taken");

      const trainerId = newId("tr");
      this.insertTrainer(trainerId, invite.group_id, input.email, input.credentials, now);
      this.sql.exec("UPDATE invites SET uses = uses + 1 WHERE id = ?", invite.id);
      return ok(this.grant(trainerId));
    });
  }

  recover(input: { ipHash: string; recoveryHash: string | null; credentials: NewCredentials }): Result<AccountGrant> {
    const now = this.clock();
    return this.tx(() => {
      const limited = this.checkAttempts(input.ipHash, "recovery", now);
      if (limited) return limited;
      const trainer =
        input.recoveryHash === null
          ? undefined
          : this.sql
              .exec<TrainerRow>(`SELECT ${TRAINER_COLUMNS} FROM trainers WHERE recovery_hash = ?`, input.recoveryHash)
              .toArray()[0];
      if (!trainer) return this.failAttempt(input.ipHash, "recovery", now, "invalid_code");
      if (trainer.status !== "active") return this.failAttempt(input.ipHash, "recovery", now, "account_left");

      this.sql.exec(
        "UPDATE trainers SET key_hash = ?, recovery_hash = ? WHERE id = ?",
        input.credentials.keyHash,
        input.credentials.recoveryHash,
        trainer.id,
      );
      return ok(this.grant(trainer.id));
    });
  }

  reconnect(input: {
    ipHash: string;
    codeHash: string | null;
    email: Email | null;
    credentials: NewCredentials;
  }): Result<AccountGrant> {
    const now = this.clock();
    return this.tx(() => {
      const limited = this.checkAttempts(input.ipHash, "reconnect", now);
      if (limited) return limited;
      const code =
        input.codeHash === null
          ? undefined
          : this.sql
              .exec<ReconnectRow>(
                "SELECT id, group_id, trainer_id, expires_at, used_at, voided_at FROM reconnect_codes WHERE code_hash = ?",
                input.codeHash,
              )
              .toArray()[0];
      if (!code) return this.failAttempt(input.ipHash, "reconnect", now, "invalid_code");
      if (code.used_at !== null) return this.failAttempt(input.ipHash, "reconnect", now, "code_used");
      if (code.voided_at !== null || now >= code.expires_at) {
        return this.failAttempt(input.ipHash, "reconnect", now, "code_expired");
      }
      const trainer = this.access.trainerInGroup(code.trainer_id, code.group_id);
      if (!trainer) return fail("internal");

      if (trainer.status === "left") {
        if (!input.email) return fail("bad_request");
        if (this.emailTaken(code.group_id, input.email.norm)) return fail("display_email_taken");
        this.sql.exec(
          `UPDATE trainers SET status = 'active', display_email = ?, email_norm = ?, key_hash = ?, recovery_hash = ?, left_at = NULL
           WHERE id = ?`,
          input.email.display,
          input.email.norm,
          input.credentials.keyHash,
          input.credentials.recoveryHash,
          trainer.id,
        );
      } else {
        this.sql.exec(
          "UPDATE trainers SET key_hash = ?, recovery_hash = ? WHERE id = ?",
          input.credentials.keyHash,
          input.credentials.recoveryHash,
          trainer.id,
        );
      }
      this.sql.exec("UPDATE reconnect_codes SET used_at = ? WHERE id = ?", now, code.id);
      this.addAudit(code.group_id, now, "reconnect_code_used", trainer.id, trainer.id, null);
      return ok(this.grant(trainer.id));
    });
  }

  // ---- RPC: access-key entry points ----

  me(input: { keyHash: string }): Result<AccountGrant> {
    return this.tx(() => {
      const auth = this.access.actor(input.keyHash, "member");
      if (!auth.ok) return auth;
      const actor = auth.value;
      return ok(this.grant(actor.trainer.id));
    });
  }

  group(input: { keyHash: string }): Result<{ group: GroupView; members: MemberView[] }> {
    return this.tx(() => {
      const auth = this.access.actor(input.keyHash, "member");
      if (!auth.ok) return auth;
      const actor = auth.value;
      const group = this.groupRow(actor.groupId);
      const members = this.sql
        .exec<TrainerRow>(`SELECT ${TRAINER_COLUMNS} FROM trainers WHERE group_id = ? ORDER BY joined_at, id`, actor.groupId)
        .toArray()
        .map((row) => ({ ...this.trainerView(row, group), joinedAt: row.joined_at }));
      return ok({ group: this.groupView(group), members });
    });
  }

  audit(input: { keyHash: string }): Result<{ entries: AuditEntry[] }> {
    return this.tx(() => {
      const auth = this.access.actor(input.keyHash, "member");
      if (!auth.ok) return auth;
      const actor = auth.value;
      const entries = this.sql
        .exec<AuditRow>(
          "SELECT id, at, kind, actor_id, target_id, invite_id FROM audit WHERE group_id = ? ORDER BY id DESC LIMIT ?",
          actor.groupId,
          AUDIT_PAGE,
        )
        .toArray()
        .map((row) => ({
          id: row.id,
          at: row.at,
          kind: row.kind,
          actorTrainerId: row.actor_id,
          targetTrainerId: row.target_id,
          inviteId: row.invite_id,
        }));
      return ok({ entries });
    });
  }

  createInvite(input: { keyHash: string; inviteHash: string; ttlMs: number; maxUses: number }): Result<InviteView> {
    const now = this.clock();
    return this.tx(() => {
      const auth = this.access.actor(input.keyHash, "host");
      if (!auth.ok) return auth;
      const actor = auth.value;
      const id = newId("inv");
      this.sql.exec(
        `INSERT INTO invites (id, group_id, code_hash, created_by, created_at, expires_at, max_uses, uses)
         VALUES (?, ?, ?, ?, ?, ?, ?, 0)`,
        id,
        actor.groupId,
        input.inviteHash,
        actor.trainer.id,
        now,
        now + input.ttlMs,
        input.maxUses,
      );
      this.addAudit(actor.groupId, now, "invite_created", actor.trainer.id, null, id);
      return ok(this.inviteView(this.access.inviteInGroup(id, actor.groupId)!));
    });
  }

  listInvites(input: { keyHash: string }): Result<{ invites: InviteView[] }> {
    return this.tx(() => {
      const auth = this.access.actor(input.keyHash, "host");
      if (!auth.ok) return auth;
      const actor = auth.value;
      const invites = this.sql
        .exec<InviteRow>(
          `SELECT ${INVITE_COLUMNS} FROM invites WHERE group_id = ? ORDER BY created_at DESC, id`,
          actor.groupId,
        )
        .toArray()
        .map((row) => this.inviteView(row));
      return ok({ invites });
    });
  }

  revokeInvite(input: { keyHash: string; inviteId: string }): Result<InviteView> {
    const now = this.clock();
    return this.tx(() => {
      const auth = this.access.actor(input.keyHash, "host");
      if (!auth.ok) return auth;
      const actor = auth.value;
      const found = this.access.invite(actor, input.inviteId);
      if (!found.ok) return found;
      const invite = found.value;
      if (invite.revoked_at === null) {
        this.sql.exec("UPDATE invites SET revoked_at = ? WHERE id = ?", now, invite.id);
        this.addAudit(actor.groupId, now, "invite_revoked", actor.trainer.id, null, invite.id);
      }
      return ok(this.inviteView(this.access.inviteInGroup(invite.id, actor.groupId)!));
    });
  }

  issueReconnectCode(input: { keyHash: string; trainerId: string; codeHash: string }): Result<{ trainerId: string; expiresAt: number }> {
    const now = this.clock();
    return this.tx(() => {
      const auth = this.access.actor(input.keyHash, "host");
      if (!auth.ok) return auth;
      const actor = auth.value;
      const found = this.access.target(actor, input.trainerId, { activeOnly: false });
      if (!found.ok) return found;
      const target = found.value;

      this.voidReconnectCodes(target.id, now);
      const expiresAt = now + RECONNECT_TTL_MS;
      this.sql.exec(
        `INSERT INTO reconnect_codes (id, group_id, trainer_id, code_hash, created_by, created_at, expires_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
        newId("rc"),
        actor.groupId,
        target.id,
        input.codeHash,
        actor.trainer.id,
        now,
        expiresAt,
      );
      this.addAudit(actor.groupId, now, "reconnect_code_issued", actor.trainer.id, target.id, null);
      return ok({ trainerId: target.id, expiresAt });
    });
  }

  leave(input: { keyHash: string }): Result<{ ok: true }> {
    const now = this.clock();
    return this.tx(() => {
      const auth = this.access.actor(input.keyHash, "member");
      if (!auth.ok) return auth;
      const actor = auth.value;
      if (actor.isHost) return fail("host_must_transfer");
      this.anonymize(actor.trainer.id, now);
      this.addAudit(actor.groupId, now, "member_left", actor.trainer.id, actor.trainer.id, null);
      return ok({ ok: true as const });
    });
  }

  removeMember(input: { keyHash: string; trainerId: string }): Result<{ ok: true }> {
    const now = this.clock();
    return this.tx(() => {
      const auth = this.access.actor(input.keyHash, "host");
      if (!auth.ok) return auth;
      const actor = auth.value;
      const found = this.access.target(actor, input.trainerId, { activeOnly: true });
      if (!found.ok) return found;
      const target = found.value;
      this.anonymize(target.id, now);
      this.addAudit(actor.groupId, now, "member_removed", actor.trainer.id, target.id, null);
      return ok({ ok: true as const });
    });
  }

  transferHost(input: { keyHash: string; trainerId: string }): Result<{ group: GroupView }> {
    const now = this.clock();
    return this.tx(() => {
      const auth = this.access.actor(input.keyHash, "host");
      if (!auth.ok) return auth;
      const actor = auth.value;
      const found = this.access.target(actor, input.trainerId, { activeOnly: true });
      if (!found.ok) return found;
      const target = found.value;
      this.sql.exec("UPDATE groups SET host_trainer_id = ? WHERE id = ?", target.id, actor.groupId);
      this.addAudit(actor.groupId, now, "host_transferred", actor.trainer.id, target.id, null);
      return ok({ group: this.groupView(this.groupRow(actor.groupId)) });
    });
  }

  /** Deletes attempt records once they are a day old. */
  override alarm(): void {
    const now = this.clock();
    this.ctx.storage.transactionSync(() => {
      this.sql.exec("DELETE FROM meta WHERE key = 'attempts_alarm_at'");
      this.purgeAttempts(now);
    });
    this.scheduleAttemptCleanup();
  }

  // ---- internals ----

  private tx<T>(fn: () => Result<T>): Result<T> {
    const result = this.ctx.storage.transactionSync(fn);
    this.scheduleAttemptCleanup();
    return result;
  }

  private groupRow(groupId: string): GroupRow {
    const row = this.sql.exec<GroupRow>("SELECT id, name, host_trainer_id FROM groups WHERE id = ?", groupId).toArray()[0];
    if (!row) throw new Error("group missing");
    return row;
  }

  private emailTaken(groupId: string, emailNorm: string): boolean {
    return (
      this.sql
        .exec("SELECT 1 FROM trainers WHERE group_id = ? AND email_norm = ? AND status = 'active'", groupId, emailNorm)
        .toArray().length > 0
    );
  }

  private insertTrainer(id: string, groupId: string, email: Email, credentials: NewCredentials, now: number): void {
    this.sql.exec(
      `INSERT INTO trainers (id, group_id, status, display_email, email_norm, key_hash, recovery_hash, joined_at)
       VALUES (?, ?, 'active', ?, ?, ?, ?, ?)`,
      id,
      groupId,
      email.display,
      email.norm,
      credentials.keyHash,
      credentials.recoveryHash,
      now,
    );
  }

  /** Leaving keeps the id and record but drops the key and email; the recovery hash stays so it can answer account_left. */
  private anonymize(trainerId: string, now: number): void {
    this.sql.exec(
      `UPDATE trainers SET status = 'left', display_email = NULL, email_norm = NULL, key_hash = NULL, left_at = ?
       WHERE id = ?`,
      now,
      trainerId,
    );
    this.voidReconnectCodes(trainerId, now);
  }

  private voidReconnectCodes(trainerId: string, now: number): void {
    this.sql.exec(
      "UPDATE reconnect_codes SET voided_at = ? WHERE trainer_id = ? AND used_at IS NULL AND voided_at IS NULL",
      now,
      trainerId,
    );
  }

  private addAudit(
    groupId: string,
    now: number,
    kind: AuditKind,
    actorId: string | null,
    targetId: string | null,
    inviteId: string | null,
  ): void {
    this.sql.exec(
      "INSERT INTO audit (group_id, at, kind, actor_id, target_id, invite_id) VALUES (?, ?, ?, ?, ?, ?)",
      groupId,
      now,
      kind,
      actorId,
      targetId,
      inviteId,
    );
  }

  private grant(trainerId: string): AccountGrant {
    const trainer = this.sql.exec<TrainerRow>(`SELECT ${TRAINER_COLUMNS} FROM trainers WHERE id = ?`, trainerId).toArray()[0];
    if (!trainer) throw new Error("trainer missing");
    const group = this.groupRow(trainer.group_id);
    return { trainer: this.trainerView(trainer, group), group: this.groupView(group) };
  }

  private trainerView(row: TrainerRow, group: GroupRow): TrainerView {
    return {
      trainerId: row.id,
      displayEmail: row.status === "active" ? row.display_email : null,
      role: group.host_trainer_id === row.id ? "host" : "member",
      status: row.status,
    };
  }

  private groupView(row: GroupRow): GroupView {
    return { groupId: row.id, name: row.name, hostTrainerId: row.host_trainer_id };
  }

  private inviteView(row: InviteRow): InviteView {
    return {
      inviteId: row.id,
      createdAt: row.created_at,
      expiresAt: row.expires_at,
      maxUses: row.max_uses,
      uses: row.uses,
      revoked: row.revoked_at !== null,
      revokedAt: row.revoked_at,
    };
  }

  // ---- attempt limits ----

  private checkAttempts(ipHash: string, kind: AttemptKind, now: number): Fail | null {
    this.purgeAttempts(now);
    const recent = this.sql
      .exec<{ at: number }>(
        "SELECT at FROM attempts WHERE ip_hash = ? AND kind = ? AND at > ? ORDER BY at ASC",
        ipHash,
        kind,
        now - ATTEMPT_WINDOW_MS,
      )
      .toArray();
    if (recent.length < ATTEMPT_LIMIT) return null;
    // Unblocked once enough failures age out of the window to leave fewer than the limit.
    const pivot = recent[recent.length - ATTEMPT_LIMIT]!;
    const retryAfter = Math.max(1, Math.ceil((pivot.at + ATTEMPT_WINDOW_MS - now) / 1000));
    return fail("too_many_attempts", retryAfter);
  }

  private failAttempt(ipHash: string, kind: AttemptKind, now: number, code: Fail["code"]): Fail {
    this.sql.exec("INSERT INTO attempts (ip_hash, kind, at) VALUES (?, ?, ?)", ipHash, kind, now);
    return fail(code);
  }

  private purgeAttempts(now: number): void {
    this.sql.exec("DELETE FROM attempts WHERE at <= ?", now - ATTEMPT_RETENTION_MS);
  }

  /** Keeps one alarm pending while attempt records exist, so they go away a day later without traffic. */
  private scheduleAttemptCleanup(): void {
    const scheduled = this.sql.exec("SELECT value FROM meta WHERE key = 'attempts_alarm_at'").toArray().length > 0;
    if (scheduled) return;
    const oldest = this.sql.exec<{ at: number | null }>("SELECT MIN(at) AS at FROM attempts").toArray()[0]?.at ?? null;
    if (oldest === null) return;
    const at = oldest + ATTEMPT_RETENTION_MS + 1000;
    this.sql.exec("INSERT INTO meta (key, value) VALUES ('attempts_alarm_at', ?)", String(at));
    void this.ctx.storage.setAlarm(at);
  }
}
