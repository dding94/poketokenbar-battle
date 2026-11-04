/** SQL deadlines and the runtime alarm are durable. This mirror is rebuilt on every activation. */
export class AlarmScheduler {
  private at: number | null = null;
  private hint: number | null = null;
  private rescan = false;
  constructor(private readonly storage: Pick<DurableObjectStorage, "getAlarm" | "setAlarm" | "deleteAlarm">, private readonly next: () => number | null, private readonly abort: () => void) {}
  async initialize(): Promise<void> {
    this.at = await this.storage.getAlarm();
    const next = this.next();
    if (next !== null && (this.at === null || next < this.at)) this.set(next);
  }
  due(now: number): boolean { return this.at !== null && this.at <= now; }
  begin(now: number, consumed = false): void {
    this.hint = null;
    this.rescan = consumed || this.due(now);
    if (consumed) this.at = null;
  }
  changed(at: number | null): void { if (at !== null) this.hint = this.hint === null ? at : Math.min(this.hint, at); }
  discard(): void { this.hint = null; this.rescan = false; }
  finish(): void {
    const next = this.rescan ? this.next() : this.hint;
    if (next !== null && (this.at === null || next < this.at || this.rescan)) this.set(next);
    else if (next === null && this.rescan && this.at !== null) {
      this.at = null;
      try { void this.storage.deleteAlarm().catch(() => this.abort()); } catch { this.abort(); throw new Error("alarm scheduling failed"); }
    }
    this.discard();
  }
  private set(at: number): void {
    // Promise completion must never overwrite a newer, earlier committed hint.
    this.at = at;
    try { void this.storage.setAlarm(at).catch(() => this.abort()); } catch { this.abort(); throw new Error("alarm scheduling failed"); }
  }
}
