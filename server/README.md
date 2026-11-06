# PokeTokenBar Battle league server

Cloudflare Worker plus one SQLite-backed Durable Object (`League`) for groups, invites,
access keys, recovery and host reconnect codes, and the realtime connection.

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
npm test --prefix server   # vitest inside workerd via @cloudflare/vitest-plugin, then node --test for scripts/
```

Tests use obviously fake secret bindings defined in `vitest.config.ts`. There are two Vitest
projects: `api` (one Miniflare and League storage per test file) and `ws` (`test/ws/`). The
Workers Vitest integration does not support WebSockets with Durable Objects under per-file
storage isolation, so `ws` follows its documented workaround: shared storage
(`isolate: false`), one file at a time. Every WebSocket test builds its own group.
