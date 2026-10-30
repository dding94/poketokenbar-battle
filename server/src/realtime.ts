// Realtime connections of the League (Appendix C). Hibernation API only: sockets carry a
// trainer tag, a group tag and an attachment, so presence is rebuilt from the runtime's list of
// live sockets after every wake-up and is never stored or kept in memory.

/** Internal header carrying the access-key hash from the Worker to the League. */
export const KEY_HASH_HEADER = "x-ptb-key-hash";

export const CLOSE_CODES = {
  replaced: 4001,
  revoked: 4003,
  unexpected_message: 4400,
} as const;

export type CloseReason = keyof typeof CLOSE_CODES;

export type GroupChange = "join" | "leave" | "remove" | "return" | "host_transfer";

/** Per-socket state; survives hibernation. */
export interface Attachment {
  trainerId: string;
  groupId: string;
  connectedAt: number;
  /** Set once the socket has left presence (closed by the server or by the client). */
  closed?: true;
}

const OPEN = 1;

const trainerTag = (trainerId: string) => `trainer:${trainerId}`;
const groupTag = (groupId: string) => `group:${groupId}`;

function attachmentOf(ws: WebSocket): Attachment | null {
  const value = ws.deserializeAttachment() as Attachment | null;
  return value && typeof value.trainerId === "string" ? value : null;
}

function markClosed(ws: WebSocket, attachment: Attachment): void {
  try {
    ws.serializeAttachment({ ...attachment, closed: true } satisfies Attachment);
  } catch {
    // The runtime may refuse once the socket is fully closed; it is out of presence anyway.
  }
}

function tryClose(ws: WebSocket, code: number, reason: string): void {
  try {
    ws.close(code, reason);
  } catch {
    // Already closed.
  }
}

export class Realtime {
  constructor(private readonly ctx: DurableObjectState) {
    // Answered by the runtime without waking the League.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  /**
   * Accepts a trainer's socket. Older sockets of the same trainer close with 4001 after the new
   * one is live, so the trainer never looks offline in between; peers hear only a 0→1 change.
   */
  accept(server: WebSocket, trainerId: string, groupId: string, now: number): void {
    const wasOnline = this.isOnline(trainerId);
    const older = this.liveSockets(trainerTag(trainerId));
    this.ctx.acceptWebSocket(server, [trainerTag(trainerId), groupTag(groupId)]);
    server.serializeAttachment({ trainerId, groupId, connectedAt: now } satisfies Attachment);
    this.close(older, "replaced");
    if (!wasOnline) this.sendToGroup(groupId, { type: "presence", trainerId, online: true }, trainerId);
    server.send(JSON.stringify({ v: 1, type: "hello", trainerId, groupId, online: this.onlineIn(groupId) }));
  }

  isOnline(trainerId: string): boolean {
    return this.liveSockets(trainerTag(trainerId)).length > 0;
  }

  /** After a key change or revocation has committed: close the trainer's sockets with 4003. */
  revoke(trainerId: string): void {
    this.close(this.liveSockets(trainerTag(trainerId)), "revoked");
  }

  groupChanged(groupId: string, kind: GroupChange): void {
    this.sendToGroup(groupId, { type: "group_changed", kind });
  }

  /** Any client message other than the auto-answered `ping`. */
  unexpectedMessage(ws: WebSocket): void {
    this.close([ws], "unexpected_message");
  }

  /** The client closed the socket or it failed: answer the close and update presence. */
  departed(ws: WebSocket): void {
    const attachment = attachmentOf(ws);
    if (attachment && !attachment.closed) markClosed(ws, attachment);
    tryClose(ws, 1000, "");
    if (attachment && !attachment.closed) this.announceIfOffline(attachment);
  }

  /** Trainer ids with a live socket in the group, sorted. */
  private onlineIn(groupId: string): string[] {
    const ids = new Set<string>();
    for (const ws of this.liveSockets(groupTag(groupId))) ids.add(attachmentOf(ws)!.trainerId);
    return [...ids].sort();
  }

  /** Open sockets with the tag that have not left presence; closing ones are excluded. */
  private liveSockets(tag: string): WebSocket[] {
    return this.ctx.getWebSockets(tag).filter((ws) => {
      if (ws.readyState !== OPEN) return false;
      const attachment = attachmentOf(ws);
      return attachment !== null && !attachment.closed;
    });
  }

  private close(sockets: WebSocket[], reason: CloseReason): void {
    const affected: Attachment[] = [];
    for (const ws of sockets) {
      const attachment = attachmentOf(ws);
      if (!attachment || attachment.closed) continue;
      markClosed(ws, attachment);
      tryClose(ws, CLOSE_CODES[reason], reason);
      affected.push(attachment);
    }
    const seen = new Set<string>();
    for (const attachment of affected) {
      if (seen.has(attachment.trainerId)) continue;
      seen.add(attachment.trainerId);
      this.announceIfOffline(attachment);
    }
  }

  private announceIfOffline({ trainerId, groupId }: Attachment): void {
    if (!this.isOnline(trainerId)) this.sendToGroup(groupId, { type: "presence", trainerId, online: false }, trainerId);
  }

  /** Only to live sockets of this group, never to `exceptTrainerId`. */
  private sendToGroup(groupId: string, message: Record<string, unknown>, exceptTrainerId?: string): void {
    const text = JSON.stringify({ v: 1, ...message });
    for (const ws of this.liveSockets(groupTag(groupId))) {
      if (attachmentOf(ws)!.trainerId === exceptTrainerId) continue;
      try {
        ws.send(text);
      } catch {
        // A socket that failed meanwhile is reported through webSocketError/webSocketClose.
      }
    }
  }
}
