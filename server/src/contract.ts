// Fixed error codes the app translates (Appendix B), with their HTTP status.
export const ERROR_STATUS = {
  bad_request: 400,
  cannot_target_self: 400,
  unauthorized: 401,
  forbidden: 403,
  operator_denied: 403,
  account_left: 403,
  not_found: 404,
  invalid_invite: 404,
  invalid_code: 404,
  method_not_allowed: 405,
  display_email_taken: 409,
  host_must_transfer: 409,
  invite_expired: 410,
  invite_revoked: 410,
  invite_used_up: 410,
  code_expired: 410,
  code_used: 410,
  payload_too_large: 413,
  unsupported_media_type: 415,
  upgrade_required: 426,
  too_many_attempts: 429,
  internal: 500,
  operator_disabled: 503,
} as const;

export type ErrorCode = keyof typeof ERROR_STATUS;

export interface Fail {
  ok: false;
  code: ErrorCode;
  /** Seconds, only with too_many_attempts. */
  retryAfter?: number;
}

export interface Ok<T> {
  ok: true;
  value: T;
}

export type Result<T> = Ok<T> | Fail;

export function ok<T>(value: T): Ok<T> {
  return { ok: true, value };
}

export function fail(code: ErrorCode, retryAfter?: number): Fail {
  return retryAfter === undefined ? { ok: false, code } : { ok: false, code, retryAfter };
}

export type Role = "host" | "member";
export type Status = "active" | "left";

export interface TrainerView {
  trainerId: string;
  displayEmail: string | null;
  role: Role;
  status: Status;
}

export interface MemberView extends TrainerView {
  joinedAt: number;
  /** A live WebSocket right now (Appendix C); never stored. */
  online: boolean;
}

export interface GroupView {
  groupId: string;
  name: string;
  hostTrainerId: string;
}

export interface InviteView {
  inviteId: string;
  createdAt: number;
  expiresAt: number;
  maxUses: number;
  uses: number;
  revoked: boolean;
  revokedAt: number | null;
}

export type AuditKind =
  | "invite_created"
  | "invite_revoked"
  | "reconnect_code_issued"
  | "reconnect_code_used"
  | "operator_host_reconnect"
  | "member_left"
  | "member_removed"
  | "host_transferred";

export interface AuditEntry {
  id: number;
  at: number;
  kind: AuditKind;
  actorTrainerId: string | null;
  targetTrainerId: string | null;
  inviteId: string | null;
}

/** What the League returns when it grants credentials; the Worker adds the raw values. */
export interface AccountGrant {
  trainer: TrainerView;
  group: GroupView;
}

export type AttemptKind = "operator" | "invite" | "recovery" | "reconnect";
