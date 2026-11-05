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

## First group for a new environment

A new environment has no group, and the app cannot create one. Order of steps (the user does
the first three; agents never deploy or handle secret values):

1. Deploy the Worker (`npx wrangler deploy`, with the user).
2. Set the secrets `CODE_PEPPER` and `OPERATOR_SECRET` (`npx wrangler secret put <NAME>`).
3. Run `scripts/bootstrap-group.mjs`. It creates the group and prints the group id, the host
   trainer id and the host's recovery code once. It never prints the access key or the operator
   secret, writes no file and sends the secret only in the request body.
4. Paste the recovery code into the app's recovery field to connect as host.

```sh
read -rs OPERATOR_SECRET; export OPERATOR_SECRET
node server/scripts/bootstrap-group.mjs https://<worker-host> "<group name>" "<host nickname>"
unset OPERATOR_SECRET
```

The URL must be https (`http://localhost` is allowed for local runs). Server errors print only
the error code. Run it once per environment: every run creates another group.

## Measurement script

`scripts/measure.mjs` (Node 24, no dependencies) produces the PR 05 load against a deployed
environment. The operator secret comes only from the environment. Read it without echo, so it
never reaches the shell history or the terminal, then export it for the script:

```sh
read -rs OPERATOR_SECRET; export OPERATOR_SECRET
node server/scripts/measure.mjs https://ptb-battle-league-dev.<subdomain>.workers.dev \
  [--members 30] [--hold-minutes 10] [--churn 5] [--redeploy-wait-minutes 0] [--ping-seconds 30] [--cleanup]
unset OPERATOR_SECRET
```

Do not put the secret on the command line (`OPERATOR_SECRET=… node …`): the shell history
keeps it. `--members` is at most 99.

1. Creates one group named `measure <time>` (host `host@measure.invalid`), issues a one-hour
   invite, joins `--members` fake members (`m01@measure.invalid`, …) and revokes the invite.
   If setup fails or is interrupted partway, the script revokes the invite and makes the
   members that already joined leave.
2. Opens one WebSocket per member; each sends `ping` every `--ping-seconds`. A connect that has
   not opened after 15 s counts as a failure and is retried.
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
and error counts by kind. Progress goes to stderr. Ctrl-C at any point (setup included) stops
the run, cleans up as above and still prints the summary; a second Ctrl-C exits at once. Keys,
codes, the operator secret and emails stay in memory: they are never printed, written to a file
or put in a URL. The summary names the target only by the Worker's first host label
(`ptb-battle-league-dev`), never the account's workers.dev subdomain. CPU, DO requests,
row writes and GB-s come from the Cloudflare dashboard and analytics, not from the script.
For the idle-disconnect time, run with a `--ping-seconds` longer than the expected cutoff and
read `unexpectedDrops.connectedForMs`.

### Local battle cost measurement

Run `npm run measure:battles` for synthetic matches inside local workerd. It creates a
separate disposable League object per scenario and uses fake accounts/snapshots. It
never connects to the deployed Worker. Scenarios include 25/200 manual rounds, a
10-match batch, auto rounds, timeouts, mismatching/missing reports, and reconnects.

Each JSON result reports battle HTTP calls (including WebSocket upgrades), League
RPC calls, forced runtime alarm invocations, SQL cursor `rowsRead` and `rowsWritten` (already
including index writes), `setAlarm` calls, and application `deleteAlarm` calls separately. The pinned test
helper consumes each forced alarm using `deleteAlarm`; these are reported as
`harnessAlarmDeletes` and excluded from application deletes.
Account setup, schema migration, measurement queries and test-control RPCs are
excluded. Outgoing WebSocket notifications are not incoming requests. No CPU or
actual Free-plan billing is measured here.

`retainedCellBytes` sums UTF-8 text and 8-byte numeric cells in battle tables; it
excludes SQLite headers and indexes. `databaseDeltaBytes` uses `sql.databaseSize`
after minus before the match, including page allocation and indexes. Initial
empty table pages make single-match deltas smaller than steady growth; use the
10-match batch when estimating retention. IDs and cryptographic random values
can change the retained byte totals slightly between runs. These local values
are evidence for capacity planning, not a deployment or a guarantee of daily
Free-plan headroom; account-wide traffic and the actual plan limits still apply.
