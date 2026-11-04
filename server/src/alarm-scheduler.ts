/** SQL deadlines and the runtime alarm are durable. This mirror is rebuilt on every activation. */
export class AlarmScheduler {
  private at: number | null = null;
  private hint: number | null = null;
  private rescan = false;
  private repairPending = false;
  constructor(private readonly storage: Pick<DurableObjectStorage, "getAlarm" | "setAlarm" | "deleteAlarm">, private readonly next: () => number | null, private readonly abort: () => void) {}
  async initialize(): Promise<void> {
    this.at = await this.storage.getAlarm();
    const next = this.next();
    // A cold alarm has already been consumed before the constructor runs. Let its
    // actual event reconcile once, rather than writing here and again in alarm().
    if (next !== null && (this.at === null || next < this.at)) { this.at = 0; this.repairPending = true; }
  }
  repair(now: number): void { if (this.repairPending) { this.begin(now); this.finish(); } }
  due(now: number): boolean { return this.at !== null && this.at <= now; }
  begin(now: number, consumed = false): void {
    this.hint = null;
    this.rescan = consumed || this.due(now);
    if (consumed) this.at = null;
  }
  changed(at: number | null): void { if (at !== null) this.hint = this.hint === null ? at : Math.min(this.hint, at); }
  discard(): void { this.hint = null; this.rescan = false; this.repairPending = false; }
  rollback(): void {
    // A consumed alarm may have failed before changing any SQL deadline. Do not let a
    // request arriving before the runtime retry mistake a null mirror for no due work.
    this.at = 0;
    this.discard();
    this.repairPending = true;
  }
  finish(): void {
    let next: number | null;
    try { next = this.rescan ? this.next() : this.hint; }
    catch (error) { this.rollback(); throw error; } // SQL may already be committed; invalidate only the mirror.
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
