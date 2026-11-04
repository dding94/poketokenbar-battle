# PokeTokenBar Battle release preparation

The fork has not completed public release acceptance. Development ZIPs, including PR 13's ad-hoc build, are not public releases. Version, actual signing identity, release targets and notes/images require separate confirmation before publication. A script passing local checks does not complete two-Mac acceptance, Free-plan measurement/recovery, Gatekeeper, or company policy validation.

## Safe local commands

| Command | Behavior | Required input |
|---|---|---|
| `./scripts/release.sh --check-only` | Reads fork origin/source identity and committed documentation/image changes. No build or GitHub access. | None |
| `./scripts/release.sh --prepare <version>` | Validates local source/documents and release notes; prints targets and remaining blockers. Works on feature branches. No signing identity or GitHub access. | Candidate version, notes, contributor roster |
| `./scripts/release.sh --prepare-build <version>` | Verifies exact-HEAD full CI evidence through read-only GitHub API requests, builds without installation or local tests/OCR, validates the bundle, and creates a ZIP/cask preview under `build/release/`. Works on feature branches. | Above plus `PTB_CI_RUN_ID`, GitHub Actions read access, approved existing signing identity and pinned public certificate leaf |
| `./scripts/release.sh <version>` | Separately authorized publication; requires explicit readiness, clean `main`, and an existing compatible fork cask. | All above, explicit user approval and publication access |

Check-only returns the document check's actual exit status: 0 means its local checks passed, 1 means a warning/failed preflight, 2 means the mandatory new UI asset gate failed. It does not declare external release readiness. Preparation modes never edit the tracked version, install/terminate apps, create keys/certificates, commit, push, tag, publish a GitHub Release, or modify a tap/Pages.

Prepare notes by copying [the existing template](docs/reference/release-notes-template.md) to a temporary file and filling every section. Supply verified external contributor handles, one per line, in a second temporary file; use an empty file only when there are none. Then select a candidate version and run:

```bash
PTB_NOTES_FILE=/tmp/ptb-notes.md \
PTB_CONTRIBUTORS_FILE=/tmp/ptb-contributors.txt \
  ./scripts/release.sh --prepare <version>
```

For an explicitly requested local release build, select an already completed full CI run with `PTB_CI_RUN_ID`. The numeric ID selects evidence; it does not assert success. The script uses the existing `gh` authentication for read-only GitHub API requests, without reading/printing tokens or publishing anything. It requires the fork's CI workflow at the exact current HEAD, eight successful required jobs (both app shards, test-union, secret-scan, server, both macOS determinism jobs, and changes), their required successful steps, and that same run attempt's rest-job log proving all three named native acceptance tests passed with zero native skips. A partial/skipped dispatch, old SHA, missing/expired log, unavailable API, or contradictory run/job identity blocks the build before signing. Existing opt-in skips are still unverified and are not counted as passes.

Tracked changes and untracked build/test inputs invalidate exact-HEAD evidence. Ignored build outputs and ordinary untracked log files do not. Preparation never invokes the local broad test gate, OCR, native acceptance Worker, or app. CI remains the full-suite criterion; local platform-specific test failures are not bypassed or called passes. After source integration, request the complete standard-runner CI with `gh workflow run ci.yml --ref <branch> -f scope=all`, wait for it to finish, then use its actual successful run ID; do not substitute a previous green commit. The release script only reads CI evidence and never dispatches a workflow itself. Full scope forces both macOS determinism runners even if a single runner is selected.

Then supply the approved existing certificate's public SHA-1 as `PTB_EXPECTED_LEAF` and its name as `CODESIGN_IDENTITY`, then use `--prepare-build`. The script does not create or replace certificates. A missing/mismatched leaf stops without a prompt or fallback to ad-hoc. Signing uses the existing key only during this explicit build step; public identity/certificate metadata is inspected for validation. Do not commit private keys, signing credentials, colleague emails, or real battle records.

Every release build forces `PTB_SKIP_INSTALL=1`, `PTB_NATIVE_ARCH_ONLY=0`, and `PTB_REQUIRE_STABLE_SIGN=1`. `PTB_RELEASE_VERSION` selects the artifact version without editing `scripts/build-app.sh`. Validation checks fork bundle/executable/version, `/Applications/PokeTokenBar Battle.app` LaunchAgent target, arm64 and x86_64 individually, each Mach-O deployment target 15.0, strict code signature, public leaf equality, signed JIT entitlement, and every packaged engine trust pin. A failed rebuild removes the previous release ZIP/cask preview before building so it cannot appear current.

The cask preview uses the actual ZIP's SHA-256, `PokeTokenBarBattle.zip` under this fork's `v<version>` release URL, `PokeTokenBar Battle.app`, and macOS Sequoia (15) or later. It neither writes to a real tap nor proves that the release asset or cask is available. No Homebrew installation command is advertised until the fork cask has actually been published and verified.

## Notes, contributors, and documentation

Keep English `New / Fixed / Other / Contributors` sections and `Install / Upgrade` guidance. Use `None.` for an empty change category. Review every PR/direct commit from the preceding public fork release (or the fork's starting point for its first release), including actual human contributors; do not copy an older roster. Notes must reference the fork ZIP/app and replace only the fork app. Upstream installation commands are rejected.

If no external contributor exists, use exactly `No external contributors in this release.` Otherwise list verified `@handles` and thank them. `PTB_CONTRIBUTORS_FILE` is mandatory. The checker catches missing handles; completeness still requires the PR/commit review. Release commits have no automatic coauthor. An explicitly verified `PTB_COAUTHORS_FILE` may contain `Name <email>` lines for actual coauthors only.

Update README.md/ko/ja, applicable fork screenshots, and any confirmed fork landing page consistently. New UI features need new assets; committed staleness/coverage checks do not replace visual review. Do not publish or create a landing page/tap merely to make a gate pass. Original license/author attribution and unofficial fan-project notices remain required.

## Publication boundary and recovery

Before approving publication, review the exact version, notes/images, fork source, signed ZIP/hash, signing trust status, existing tap/cask, installation/backup targets, and remaining acceptance results. Stable self-signing is neither Developer ID signing nor notarization and does not guarantee Gatekeeper acceptance or continuous Keychain permission. Public distribution/trust policy needs an explicit decision.

Only after approval, the publication form additionally requires `PTB_FORK_RELEASE_READY=1`. It reads `dding94/homebrew-tap/Casks/poke-token-bar-battle.rb` before the same exact-HEAD CI check/build; missing/incompatible content blocks publication. The cask must match the reviewed fork template, including its existing version/checksum. No tap is created. After all build checks, the script updates the tracked default version, commits/pushes `main`, publishes the exact ZIP/notes, then updates both cask version and SHA using the existing tap file SHA. No Pages request is made. A late failure can leave a partially published release; inspect actual remote state before retrying rather than recreating tags or changing signing identity automatically.

Installation is separate from release preparation/publication. Before an approved install/upgrade, quit the fork normally and back up `~/Library/Application Support/PokeTokenBarBattle` to a private location; keep real backups out of Git. Preserve the current app separately for rollback. Replace only `/Applications/PokeTokenBar Battle.app`; never remove `/Applications/PokeTokenBar.app` or its state. Verify the approved asset checksum, bundle ID, architectures, macOS 15 minimum, and signature before running. Test rollback against a copy of fork state in an isolated test account/`PTB_STATE_DIR`; do not overwrite a live save with a test fixture. Keychain/online key recovery is a separate operation, never solved by regenerating the signing certificate.

Two-Mac invitation → manual/auto battle → faint/heal/experience → standings, original/fork isolation, Free usage/storage and recovery remain manual acceptance items. Record actual results in `docs/AI_HANDOFF.md` and `docs/BATTLE_PLAN.md`; skipped/unexecuted work is not a pass.
