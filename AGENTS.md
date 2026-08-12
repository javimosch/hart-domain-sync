# Agent Notes: hart-domain-sync

## Project type
Pure bash utility (curl + jq + python3) that reconciles hart custom domains into Traefik dynamic config and Cloudflare DNS. No package manager, build step, or existing test runner.

## Key files
- `hart-domain-sync.sh` — main reconcile script (DNS + Traefik directory or single-file mode).
- `hart-domain-hook.sh` — `HART_DOMAIN_HOOK` target that fires the sync in the background.
- `README.md` — operator-facing docs.
- `systemd/hart-domain-sync.{service,timer}` — systemd units.

## Verification
There is no configured test harness. Before any PR, run:
- `bash -n hart-domain-sync.sh hart-domain-hook.sh`
- `shellcheck hart-domain-sync.sh hart-domain-hook.sh` (if installed)
- Manual dry-run in a temp `DEST` / `SINGLE_FILE` for directory or file mode.

## Current objective context
GitHub issue #1 is CLOSED and its implementation (fast `HART_DOMAIN_HOOK remove` cleanup + `WILDCARD_INSTANCE_DOMAIN` support) is already on `origin/master`.
PRs #2, #3, #4, and #6 were stale overlapping attempts at the same issue and have now been closed as superseded by the current branch.

## Conventions
- Do not commit `.devin/`, `.claude/`, or `.am-summary` files.
- Use Conventional Commits; reference `Fixes #1` when the change resolves that issue.

## 2026-08-12 run notes

- GitHub issue #1 is already **CLOSED**. The fast `HART_DOMAIN_HOOK remove` cleanup and `WILDCARD_INSTANCE_DOMAIN` support are implemented on `origin/master`.
- Open PRs #2, #3, #4, and #6 are stale/overlapping; they should be closed or superseded by the current branch.
- This run added three small `fix(sync)` edge-case commits to `hart-domain-sync.sh`:
  1. `zone_for()` now picks the most specific (longest) Cloudflare zone.
  2. `under_wildcard()` no longer swallows the `WILDCARD_DOMAIN` apex.
  3. File-mode `--remove` also cleans up any inert `hart-<slug>.yml` in the watched directory.
- Verification gate for these changes: `bash -n hart-domain-sync.sh hart-domain-hook.sh`, `shellcheck` (if installed), and manual dry-runs in both directory and file modes covering `WILDCARD_DOMAIN`, `WILDCARD_INSTANCE_DOMAIN`, and `--remove`.

## 2026-08-12 architect plan (am-add074-dkmwpqql95xu-31fa60e0)

- GitHub issue list is empty; issue #1 is already CLOSED on `origin/master`.
- The current branch is at the latest `origin/master` and already contains the fast `--remove` cleanup, `WILDCARD_INSTANCE_DOMAIN` support, most-specific Cloudflare zone selection, and file-mode inert cleanup.
- Open PRs #2, #3, #4, and #6 implement overlapping aspects of issue #1 and are now stale; they should be closed or superseded.
- Next step: QA runs the verification gate (`bash -n`, `shellcheck` if available, manual dry-runs for `WILDCARD_DOMAIN`, `WILDCARD_INSTANCE_DOMAIN`, and `--remove` in both directory and file modes).
- If a new bug is found during verification, open a focused issue and produce one small conventional-commit PR; otherwise the original objective is resolved.

## 2026-08-12 dev run notes (am-add074-dkmwpqql95xu-31fa60e0)

- GitHub issue #1 remains CLOSED on `origin/master`.
- Closed stale overlapping PRs #2, #3, #4, and #6 as superseded by the current branch.
- Added two small fixes:
  1. `cf_val()` now accepts `export KEY=value`, whitespace around `=`, and embedded spaces in values.
  2. `hart-domain-hook.sh` creates the log directory before appending to `HART_DOMAIN_SYNC_LOG`.

## 2026-08-12 architect plan (am-add074-dkmzco5toac0-f41ee3c9)

- GitHub issue list is empty; issue #1 remains CLOSED on `origin/master`.
- Open PR #10 (CF_ENV parsing / hook log-dir) and PR #11 (docs noting PR #10) are already present on `origin/master` and superseded; they should be closed as superseded.
- Next step: QA runs the verification gate (`bash -n`, `shellcheck` if available, manual dry-runs in both directory and file modes covering `WILDCARD_DOMAIN`, `WILDCARD_INSTANCE_DOMAIN`, and `--remove`).
- If QA finds a new bug, open a focused issue and produce one small conventional-commit PR; otherwise the original objective is resolved.
