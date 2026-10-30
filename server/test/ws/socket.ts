import { exports } from "cloudflare:workers";
import { afterAll, expect } from "vitest";
import { BASE, freshIp } from "../helpers";

// WebSocket helpers for the "ws" Vitest project (shared storage, one file at a time).

const WAIT_MS = 2000;

export interface ServerMessage {
  v: number;
  type: string;
  [field: string]: unknown;
}

export interface CloseInfo {
  code: number;
  reason: string;
}

export interface ConnectOptions {
  key?: string;
  /** Sent as the whole Authorization header instead of `Bearer <key>`. */
  authorization?: string;
  /** null sends no Upgrade header. */
  upgrade?: string | null;
  method?: string;
  headers?: Record<string, string>;
}

/** The raw response of a /v1/connect request; the socket, if any, is not accepted. */
export async function connectRaw(opts: ConnectOptions = {}): Promise<Response> {
  const headers = new Headers(opts.headers);
  headers.set("cf-connecting-ip", freshIp());
  const upgrade = opts.upgrade === undefined ? "websocket" : opts.upgrade;
  if (upgrade !== null) headers.set("upgrade", upgrade);
  if (opts.authorization !== undefined) headers.set("authorization", opts.authorization);
  else if (opts.key !== undefined) headers.set("authorization", `Bearer ${opts.key}`);
  return exports.default.fetch(new Request(`${BASE}/v1/connect`, { method: opts.method ?? "GET", headers }));
}

export class Socket {
  /** Every text frame received, in order. */
  readonly frames: string[] = [];
  closeInfo: CloseInfo | null = null;
  private cursor = 0;
  private waiters: Array<() => void> = [];

  constructor(readonly ws: WebSocket) {
    ws.addEventListener("message", (event) => {
      this.frames.push(typeof event.data === "string" ? event.data : `<binary ${String(event.data)}>`);
      this.wake();
    });
    ws.addEventListener("close", (event) => {
      this.closeInfo = { code: event.code, reason: event.reason };
      try {
        ws.close();
      } catch {
        // Already closed.
      }
      this.wake();
    });
    ws.accept();
    open.add(this);
  }

  /** Every JSON message received, in order. */
  get messages(): ServerMessage[] {
    return this.frames.filter((f) => f !== "pong").map((f) => JSON.parse(f) as ServerMessage);
  }

  private wake(): void {
    const waiters = this.waiters;
    this.waiters = [];
    for (const w of waiters) w();
  }

  private async wait<T>(probe: () => T | undefined, what: string): Promise<T> {
    const deadline = Date.now() + WAIT_MS;
    for (;;) {
      const value = probe();
      if (value !== undefined) return value;
      const left = deadline - Date.now();
      if (left <= 0) throw new Error(`timed out waiting for ${what}; frames: ${JSON.stringify(this.frames.slice(this.cursor))}`);
      await new Promise<void>((resolve) => {
        const timer = setTimeout(resolve, left);
        this.waiters.push(() => {
          clearTimeout(timer);
          resolve();
        });
      });
    }
  }

  /** The next unread frame, which must be JSON; fails on timeout. */
  async next(): Promise<ServerMessage> {
    const frame = await this.wait(() => (this.cursor < this.frames.length ? this.frames[this.cursor] : undefined), "a message");
    this.cursor += 1;
    expect(frame, "expected a JSON message").not.toBe("pong");
    return JSON.parse(frame) as ServerMessage;
  }

  /** Reads up to and including the first JSON message matching `match`. */
  async until(match: (message: ServerMessage) => boolean): Promise<ServerMessage> {
    for (;;) {
      const frame = await this.wait(() => (this.cursor < this.frames.length ? this.frames[this.cursor] : undefined), "a matching message");
      this.cursor += 1;
      if (frame === "pong") continue;
      const message = JSON.parse(frame) as ServerMessage;
      if (match(message)) return message;
    }
  }

  /** Sends `ping` and reads up to its `pong`; every frame before it must have been read already. */
  async sync(): Promise<void> {
    this.ws.send("ping");
    const frame = await this.wait(() => (this.cursor < this.frames.length ? this.frames[this.cursor] : undefined), "pong");
    this.cursor += 1;
    expect(frame, "unexpected message before pong").toBe("pong");
  }

  async closed(): Promise<CloseInfo> {
    return this.wait(() => this.closeInfo ?? undefined, "close");
  }

  /** Frames not read yet. */
  unread(): string[] {
    return this.frames.slice(this.cursor);
  }

  close(code = 1000, reason = "bye"): void {
    this.ws.close(code, reason);
  }
}

const open = new Set<Socket>();

/** Opens an accepted socket for `key` and reads its hello. */
export async function connect(key: string): Promise<{ socket: Socket; hello: ServerMessage }> {
  const res = await connectRaw({ key });
  expect(res.status, `connect status`).toBe(101);
  expect(res.webSocket).toBeTruthy();
  const socket = new Socket(res.webSocket!);
  const hello = await socket.next();
  expect(hello.type).toBe("hello");
  return { socket, hello };
}

export async function socketFor(key: string): Promise<Socket> {
  return (await connect(key)).socket;
}

/**
 * Closes the sockets a file left open and waits for the close handshake, so no socket outlives
 * its file in the shared "ws" runtime. (Each side must answer the other's close: when neither
 * did, Miniflare never shut down.)
 */
export function closeSocketsAfterAll(): void {
  afterAll(async () => {
    for (const socket of open) {
      if (socket.closeInfo) continue;
      try {
        socket.ws.close(1000, "done");
      } catch {
        // Already closed.
      }
    }
    await Promise.all([...open].map((socket) => socket.closed().catch(() => undefined)));
    open.clear();
  });
}

export function presence(trainerId: string, online: boolean): ServerMessage {
  return { v: 1, type: "presence", trainerId, online };
}

export function groupChanged(kind: string): ServerMessage {
  return { v: 1, type: "group_changed", kind };
}
