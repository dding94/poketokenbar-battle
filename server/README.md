# PokeTokenBar Battle league server

Cloudflare Worker plus one SQLite-backed Durable Object (`League`) for groups, invites,
access keys, recovery and host reconnect codes, and the realtime connection. The contracts
are Appendix B (PR 04, HTTP API) and Appendix C (PR 05, WebSocket) of `docs/BATTLE_PLAN.md`.

- `src/index.ts` is the Worker: routing, input validation, secret generation and hashing.
  Raw keys and codes never leave it; the Durable Object only receives hashes.
- `src/league.ts` is the `League` Durable Object (`idFromName("league")`), with synchronous
  SQL and `transactionSync` for every check-then-write.
- `src/access.ts` is the single authentication and group-permission boundary: bearer key
  hashing in the Worker, and actor/role/same-group target checks in the League.
- `src/realtime.ts` holds the League's WebSockets (Hibernation API only): `GET /v1/connect`
  upgrades, `ping`/`pong` auto-response, `hello`/`presence`/`group_changed` messages and the
  4001/4003/4400 closes. Presence comes from the live sockets' tags and attachments and is
  never stored. Revocation and `group_changed` run only after their transaction commits.
- `src/ip.ts` buckets client IPs for attempt limits: IPv6 per /64, IPv4 (and IPv4-mapped
  IPv6) per address.

## Commands

Node 24.14.0, from the repository root:

```sh
npm ci --prefix server
npm run typecheck --prefix server
npm test --prefix server   # vitest inside workerd via @cloudflare/vitest-plugin
```

Tests use obviously fake secret bindings defined in `vitest.config.ts`. There are two Vitest
projects: `api` (one Miniflare and League storage per test file) and `ws` (`test/ws/`). The
Workers Vitest integration does not support WebSockets with Durable Objects under per-file
storage isolation, so `ws` follows its documented workaround: shared storage
(`isolate: false`), one file at a time. Every WebSocket test builds its own group.

## Deployment

This package has no deploy script. Deploys are done by the user, never by an agent or CI.
PR 05 deploys only the measurement environment `env.dev` (Worker `ptb-battle-league-dev`,
its own League storage); production waits for PR 13. Appendix C fixes the order: confirm the
Free plan and register the workers.dev subdomain, deploy once
(`npx wrangler deploy --env dev`), then set `OPERATOR_SECRET` and `CODE_PEPPER` with
`npx wrangler secret put <NAME> --env dev`, then measure. Secret values are never written to
the repository. Workers Logs/observability stays explicitly off in both environments.

## Measurement script

`scripts/measure.mjs` (Node 24, no dependencies) produces the PR 05 load against a deployed
environment. The operator secret comes only from the environment:

```sh
OPERATOR_SECRET=… node server/scripts/measure.mjs https://ptb-battle-league-dev.<subdomain>.workers.dev \
  [--members 30] [--hold-minutes 10] [--churn 5] [--redeploy-wait-minutes 0] [--ping-seconds 30] [--cleanup]
```

1. Creates one group named `measure <time>` (host `host@measure.invalid`), issues a one-hour
   invite, joins `--members` fake members (`m01@measure.invalid`, …) and revokes the invite.
2. Opens one WebSocket per member; each sends `ping` every `--ping-seconds`.
3. Holds for `--hold-minutes`, then closes and reopens `--churn` sockets one by one to produce
   presence traffic.
4. With `--redeploy-wait-minutes`, asks on stderr for a redeploy and waits. Dropped sockets
   reconnect with the Appendix C rule: a random delay below `min(60 s, 1 s × 2^n)`, the count
   reset after a minute connected, no retry after 4001/4003 (or 4400), and a ten-minute retry
   once three connects in a row fail (where the app would switch to polling).
5. With `--cleanup`, every member leaves at the end. The host cannot leave
   (`host_must_transfer`) and groups cannot be deleted, so the group stays.

stdout gets a JSON summary: HTTP statuses and latencies per route, connects, message counts by
type, pings and pong round trips, closes by phase and code, unexpected drops with how long the
socket had been up, reconnect delays and outage lengths (overall and for the redeploy phase),
and error counts by kind. Progress goes to stderr. Keys, codes, the operator secret and emails
stay in memory: they are never printed, written to a file or put in a URL. CPU, DO requests,
row writes and GB-s come from the Cloudflare dashboard and analytics, not from the script.
For the idle-disconnect time, run with a `--ping-seconds` longer than the expected cutoff and
read `unexpectedDrops.connectedForMs`.
