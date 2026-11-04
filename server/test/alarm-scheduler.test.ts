import { expect, it, vi } from "vitest";
import { AlarmScheduler } from "../src/alarm-scheduler";
function fixture(persisted: number | null, next: number | null) {
  const state = { persisted, next };
  const storage = { getAlarm: vi.fn(async () => state.persisted), setAlarm: vi.fn(async (at: number | Date) => { state.persisted = Number(at); }), deleteAlarm: vi.fn(async () => { state.persisted = null; }) };
  const abort = vi.fn(), read = vi.fn(() => state.next), scheduler = new AlarmScheduler(storage, read, abort);
  return { state, storage, abort, read, scheduler };
}
it.each([null, 200])("repairs missing or late persisted alarm %s on activation", async persisted => {
  const f = fixture(persisted, 100); await f.scheduler.initialize(); f.scheduler.repair(1);
  expect(f.state.persisted).toBe(100); expect(f.storage.getAlarm).toHaveBeenCalledOnce();
});
it("preserves an earlier persisted alarm on activation and reconciles a consumed early wake", async () => {
  const f = fixture(50, 100); await f.scheduler.initialize(); expect(f.storage.setAlarm).not.toHaveBeenCalled();
  f.scheduler.begin(50, true); f.scheduler.finish(); expect(f.state.persisted).toBe(100); expect(f.storage.setAlarm).toHaveBeenCalledOnce();
});
it("does not let reversed async completion replace a more recent earlier alarm", async () => {
  const f = fixture(100, 100); await f.scheduler.initialize();
  const pending: (() => void)[] = [];
  f.storage.setAlarm.mockImplementation(at => { f.state.persisted = Number(at); return new Promise<void>(resolve => pending.push(resolve)); });
  for (const at of [90, 80]) { f.scheduler.begin(1); f.scheduler.changed(at); f.scheduler.finish(); }
  pending[1]!(); await Promise.resolve(); pending[0]!(); await Promise.resolve();
  f.scheduler.begin(1); f.scheduler.changed(85); f.scheduler.finish();
  expect(f.storage.setAlarm.mock.calls.map(c => c[0])).toEqual([90, 80]); expect(f.state.persisted).toBe(80); expect(f.scheduler.due(85)).toBe(true);
});
it.each([false, true])("aborts the instance on a %s synchronous scheduling failure", async synchronous => {
  const f = fixture(100, 100); await f.scheduler.initialize();
  f.storage.setAlarm.mockImplementation(() => { if (synchronous) throw new Error("fault"); return Promise.reject(new Error("fault")); });
  f.scheduler.begin(1); f.scheduler.changed(50);
  if (synchronous) expect(() => f.scheduler.finish()).toThrow("alarm scheduling failed"); else { f.scheduler.finish(); await Promise.resolve(); }
  expect(f.abort).toHaveBeenCalledOnce();
});
it("propagates activation reads to blockConcurrencyWhile so a failed initialization cannot serve traffic", async () => {
  const f = fixture(100, 100); f.storage.getAlarm.mockRejectedValue(new Error("fault"));
  await expect(f.scheduler.initialize()).rejects.toThrow("fault"); expect(f.storage.setAlarm).not.toHaveBeenCalled();
});
it("discards only thrown-transaction hints and keeps hints from committed failures", async () => {
  const f = fixture(100, 100); await f.scheduler.initialize();
  f.scheduler.begin(1); f.scheduler.changed(20); f.scheduler.discard();
  f.scheduler.begin(1); f.scheduler.changed(50); f.scheduler.finish();
  expect(f.storage.setAlarm.mock.calls.map(c => c[0])).toEqual([50]);
});
it("uses SQL truth after a late request and after duplicate alarm delivery", async () => {
  const f = fixture(50, 50); await f.scheduler.initialize();
  f.scheduler.begin(51); f.state.next = 100; f.scheduler.finish(); expect(f.state.persisted).toBe(100);
  f.scheduler.begin(51, true); f.state.next = 75; f.scheduler.finish(); expect(f.state.persisted).toBe(75);
  f.scheduler.begin(51, true); f.scheduler.finish(); expect(f.state.persisted).toBe(75);
});
it("fails closed when the post-commit deadline scan fails after alarm consumption", async () => {
  const f = fixture(50, 50); await f.scheduler.initialize();
  f.scheduler.begin(50, true); f.read.mockImplementationOnce(() => { throw new Error("read fault"); });
  expect(() => f.scheduler.finish()).toThrow("read fault"); expect(f.scheduler.due(51)).toBe(true);
  f.state.next = 75; f.scheduler.begin(51); f.scheduler.finish(); expect(f.state.persisted).toBe(75);
});
it("removes a consumed late request's obsolete alarm and aborts if deletion fails", async () => {
  const f = fixture(50, 50); await f.scheduler.initialize();
  f.scheduler.begin(51); f.state.next = null; f.storage.deleteAlarm.mockRejectedValue(new Error("fault")); f.scheduler.finish(); await Promise.resolve();
  expect(f.storage.deleteAlarm).toHaveBeenCalledOnce(); expect(f.abort).toHaveBeenCalledOnce();
});
