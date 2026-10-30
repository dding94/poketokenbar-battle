# PokeTokenBar Battle league server

Cloudflare Worker plus one SQLite-backed Durable Object (`League`) for groups, invites,
access keys, recovery and host reconnect codes. The contract is Appendix B of
`docs/BATTLE_PLAN.md` (PR 04).

- `src/index.ts` is the Worker: routing, input validation, secret generation and hashing.
  Raw keys and codes never leave it; the Durable Object only receives hashes.
- `src/league.ts` is the `League` Durable Object (`idFromName("league")`), with synchronous
  SQL and `transactionSync` for every check-then-write.
- `src/access.ts` is the single authentication and group-permission boundary: bearer key
  hashing in the Worker, and actor/role/same-group target checks in the League.

## Commands

Node 24.14.0, from the repository root:

```sh
npm ci --prefix server
npm run typecheck --prefix server
npm test --prefix server   # vitest inside workerd via @cloudflare/vitest-plugin
```

Tests use obviously fake secret bindings defined in `vitest.config.ts`.

## No deployment

This package has no deploy script and PR 04 does not deploy. Do not run `wrangler deploy`
or `wrangler login`. Real `OPERATOR_SECRET` and `CODE_PEPPER` values are set as Worker
secrets at deployment time (PR 05, with user approval) and are never written to the
repository. Workers Logs/observability stays off in `wrangler.jsonc`.
