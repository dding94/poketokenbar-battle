import { DurableObject } from "cloudflare:workers";

export class League extends DurableObject<Env> {
  /** Single clock for every time check. Tests replace it through runInDurableObject. */
  clock: () => number = () => Date.now();
}
