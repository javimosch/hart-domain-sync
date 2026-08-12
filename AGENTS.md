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
Open issue #1: fast `HART_DOMAIN_HOOK remove` cleanup + `WILDCARD_INSTANCE_DOMAIN` support so externally-managed wildcard subdomains are skipped.
Existing open PRs #2, #3, and #4 already attempt overlapping changes for the same issue; new work should implement from the current base and not rely on those unmerged branches.

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
