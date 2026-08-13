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

## 2026-08-12 architect plan (am-add074-dkn07a9q0gcb-61a8777a)

- `gh issue list --state open` returned `[]`; no open GitHub issues to fix.
- `gh pr list --state open` returned `[]`; stale PRs #2/#3/#4/#6/#10/#11 are already closed/superseded.
- `git status` is clean and the branch is at `origin/master` (commit `71ecd69`).
- `bash -n hart-domain-sync.sh hart-domain-hook.sh` passes.
- `shellcheck` is not installed in this environment; QA should run it if available on the target host.
- The current codebase already contains all fixes for issue #1 (fast `HART_DOMAIN_HOOK remove`, `WILDCARD_INSTANCE_DOMAIN`, most-specific Cloudflare zone, file-mode inert cleanup, `cf_val()` env-file parsing, hook log-dir creation).
- Next step: QA runs the manual verification gate (dry-runs for `WILDCARD_DOMAIN`, `WILDCARD_INSTANCE_DOMAIN`, and `--remove` in both directory and file modes) and `shellcheck` if installed.
- If QA finds a new bug, open a focused GitHub issue and produce one small conventional-commit PR; otherwise the original objective is resolved.

## 2026-08-12 architect plan (am-add074-dkn1zmbpr35b-e5e31d75)

- `gh issue list --state open` returned `[]`; issue #1 remains CLOSED on `origin/master`.
- `gh pr list --state open` shows only PR #14 (`am/am-add074-dkn13g7iod3q-9a485f95`). That branch contains a real `fix(sync): lower-case hart domains and wildcard inputs` change, but it is bundled with a stale `docs(agents)` plan and its title does not match the code diff. PR #14 should be superseded by a clean, self-contained PR from the current branch.
- Dev should land one small conventional commit on this branch:
  1. `fix(sync): lower-case hart domains and wildcard inputs` — normalize `WILDCARD_DOMAIN` and `WILDCARD_INSTANCE_DOMAIN` to lowercase after the config is sourced, and lower-case hart-fetched domains before the `grep` filter and wildcard matching, so mixed-case hart entries are not silently dropped and uppercase wildcard env values still match.
- QA runs the verification gate after the dev commit:
  - `bash -n hart-domain-sync.sh hart-domain-hook.sh`
  - `shellcheck hart-domain-sync.sh hart-domain-hook.sh` (if installed)
  - manual dry-runs in both directory and file modes covering `WILDCARD_DOMAIN`, `WILDCARD_INSTANCE_DOMAIN`, and `--remove`
  - regression tests for the new fix: mixed-case hart domain entries, uppercase `WILDCARD_DOMAIN`/`WILDCARD_INSTANCE_DOMAIN` values, and confirm the generated Traefik rule and DNS target are lowercase.
- If QA finds a bug, dev fixes it in a focused commit; if the gate passes, close PR #14 as superseded and the original objective is resolved.

## 2026-08-13 architect plan (am-add074-dknmeo43j24t-079eea16)

- `gh issue list --state open` returns issues #16 and #17, both describing the same bug: mixed-case hart domain entries are rejected by the `^[a-z0-9.-]+$` regex and uppercase `WILDCARD_DOMAIN` / `WILDCARD_INSTANCE_DOMAIN` env values fail the strict-subdomain `case` match.
- The current `origin/master` (commit `4f10e16`) already contains the lower-case normalization fix:
  - `WILDCARD_DOMAIN` and `WILDCARD_INSTANCE_DOMAIN` are forced to lowercase after the config file is sourced.
  - hart-fetched domains are lowercased with `tr 'A-Z' 'a-z'` before the `grep` validation and before wildcard matching.
- The current branch `am/am-add074-dknmeo43j24t-079eea16` is at the same commit as `origin/master`, so no additional code change is required to resolve the reported bug.
- The next step is to close #16 and #17 as resolved by the existing `origin/master` code, and to close stale PR #14 (the earlier bundling version of the same fix) and PR #18 (shellcheck source directive, already present on `origin/master`) as superseded.
- QA should still run the verification gate:
  - `bash -n hart-domain-sync.sh hart-domain-hook.sh`
  - `shellcheck hart-domain-sync.sh hart-domain-hook.sh` (if installed)
  - manual dry-runs in both directory and file modes that specifically exercise mixed-case hart entries and uppercase `WILDCARD_DOMAIN` / `WILDCARD_INSTANCE_DOMAIN` values
  - confirm the generated Traefik `Host()` / `HostRegexp()` rules and Cloudflare DNS targets are lowercase
- If QA finds a regression or an uncovered edge case, open a focused issue and produce a small conventional-commit PR; otherwise mark the objective resolved and close the stale PRs.

## 2026-08-13 architect plan (am-add074-dknnxq87ed8m-db2ba47f)

- `gh issue list --state open` returns `[]`; issues #1, #16, and #17 are all CLOSED. No open GitHub issues remain to fix.
- `gh pr list --state open` returns `[]`; all stale/overlapping PRs are now closed or merged, including #19 (`docs(agents): add current run architect plan and close issues #16/#17`) which is merged into `origin/master`.
- The current branch `am/am-add074-dknnxq87ed8m-db2ba47f` is at the same commit as `origin/master` (`7361cf1`), and the lower-case normalization fix for the bug reported in #16/#17 is already present in `hart-domain-sync.sh`:
  - `WILDCARD_DOMAIN` and `WILDCARD_INSTANCE_DOMAIN` are normalized to lowercase after the env file is sourced (lines 54–55).
  - `REMOVE_DOMAIN` is lowercased on the `--remove` path (line 73).
  - hart-fetched domains are lowercased with `tr '[:upper:]' '[:lower:]'` before the `grep` validation and wildcard matching (line 225).
  - Cloudflare zone names are lowercased before zone selection (line 291).
- `bash -n hart-domain-sync.sh hart-domain-hook.sh` passes; `shellcheck` is not installed in this environment.
- No additional code change is required to resolve the reported bugs. The next step is for QA to run the verification gate:
  - `bash -n hart-domain-sync.sh hart-domain-hook.sh`
  - `shellcheck hart-domain-sync.sh hart-domain-hook.sh` (if installed)
  - manual dry-runs in both directory and file modes with mixed-case hart entries and uppercase `WILDCARD_DOMAIN` / `WILDCARD_INSTANCE_DOMAIN` values
  - exercise `--remove` on mixed-case domains and confirm the per-domain file / merged router and DNS records are handled correctly
  - confirm generated Traefik `Host()` / `HostRegexp()` rules and Cloudflare DNS targets are lowercase
- If QA finds an uncovered bug or regression, open a focused issue and produce one small conventional-commit PR; otherwise the objective is resolved and no further action is needed.

## 2026-08-13 architect plan (am-add074-dknpq1rqnoix-08b03afe)

- `gh issue list --state open` returns `[]`; issues #1, #16, and #17 are CLOSED. No open GitHub issues remain to fix.
- `gh pr list --state open` returns only PR #21 (`am/am-add074-dknotw3vct3i-246c2c03`), which is merge-conflicting and stale. Its `hart-domain-sync.sh` changes partially overlap with `origin/master` (commit `72de66a`), which already contains the trailing-slash and `if/else` logging refactors.
- Two real, unmerged robustness fixes remain in PR #21 and should land on this branch as clean, separate conventional commits:
  1. `fix(cf): build curl args in an array to safely quote JSON body` — replace `${d:+--data "$d"}` with an `args` array so JSON payloads with spaces/special characters are passed as a single argument to `curl`.
  2. `fix(sync): avoid unquoted expansion in zone_for suffix pattern` — replace the `${d%…}` suffix test with a `case` pattern that treats the zone name as a literal suffix and prevents glob mis-matches.
- The current branch `am/am-add074-dknpq1rqnoix-08b03afe` is at `origin/master` (`72de66a`) with a clean worktree.
- Dev applies the two fixes to `hart-domain-sync.sh` only; do not bundle the stale AGENTS.md plan from PR #21.
- QA runs the verification gate:
  - `bash -n hart-domain-sync.sh hart-domain-hook.sh`
  - `shellcheck hart-domain-sync.sh hart-domain-hook.sh`
  - manual dry-runs in both directory and file modes covering `WILDCARD_DOMAIN`, `WILDCARD_INSTANCE_DOMAIN`, mixed-case hart entries, and `--remove`
  - regression tests for the two new fixes: a JSON body containing spaces/special characters, and `zone_for()` with zone names that contain glob-like characters
- If the gate passes, close PR #21 as superseded and the original objective is resolved. If QA finds a regression, open a focused GitHub issue and produce one small conventional-commit PR.

## 2026-08-13 architect plan (am-add074-dknsg269nahy-53715114)

- `gh issue list --state open` returns `[]`; issues #1, #16, and #17 are CLOSED. No open GitHub issues remain to fix.
- `gh pr list --state open` returns only PR #21 (`am/am-add074-dknotw3vct3i-246c2c03`). Its `hart-domain-sync.sh` changes are now all present on `origin/master` (commit `ebd20ce`): the trailing-slash stripping of `HART_URL` and `SERVICE_URL`, the `&& log || log` to `if/else` refactor, the `zone_for()` `case`-pattern suffix check, and the `cf()` curl `args` array (the latter two via merged PR #23). PR #21 is merge-conflicting and stale; it should be closed as superseded without merging its bundled `AGENTS.md` plan.
- The current branch `am/am-add074-dknsg269nahy-53715114` is at `origin/master` (`ebd20ce`) with a clean worktree; `bash -n hart-domain-sync.sh hart-domain-hook.sh` passes and `shellcheck` is not installed in this environment.
- No additional code change is required to resolve the reported bugs. The next step is for QA to run the verification gate:
  - `bash -n hart-domain-sync.sh hart-domain-hook.sh`
  - `shellcheck hart-domain-sync.sh hart-domain-hook.sh` (if installed)
  - manual dry-runs in both directory and file modes covering `WILDCARD_DOMAIN`, `WILDCARD_INSTANCE_DOMAIN`, mixed-case hart entries, and `--remove`
  - regression tests for the robustness fixes now in master: a JSON body containing spaces/special characters, `zone_for()` with zone names containing glob-like characters, trailing-slash `HART_URL`/`SERVICE_URL`, and uppercase wildcard inputs
  - confirm generated Traefik `Host()` / `HostRegexp()` rules and Cloudflare DNS targets are lowercase
- If QA finds a regression or an uncovered edge case, open a focused GitHub issue and produce one small conventional-commit PR; otherwise the original objective is resolved, close PR #21 as superseded, and no further action is needed.

## 2026-08-13 architect plan (am-add074-dknug13ql7lh-39b8ae4b)

- `gh issue list --state open` returns `[]`; issues #1, #16, and #17 are CLOSED. No open GitHub issues remain to fix.
- `gh pr list --state open` returns only PR #25 (`am/am-add074-dkntjvjpixt5-e9b01c3a`). Its code changes are three real, unmerged robustness fixes that are not yet on `origin/master` (`1164718`):
  1. `fix(sync): strip all trailing slashes from HART_URL and SERVICE_URL` — replace the single `${var%/}` with a `while [[ ... == */ ]]` loop so values like `http://127.0.0.1:8799//` become clean base URLs.
  2. `fix(hook): validate remove argument before dispatching` — in `hart-domain-hook.sh`, reject `remove` events with an empty domain before calling `hart-domain-sync --remove ""`.
  3. `fix(cf): build Cloudflare record JSON with jq` — in `cf_upsert()`, use `jq -n --arg/--argjson` to escape record name/type/content safely.
- Dev should land these as three clean, separate conventional commits on this branch; do not bundle the stale `AGENTS.md` section from PR #25.
- QA runs the verification gate:
  - `bash -n hart-domain-sync.sh hart-domain-hook.sh`
  - `shellcheck hart-domain-sync.sh hart-domain-hook.sh` (if installed)
  - manual dry-runs in both directory and file modes covering `WILDCARD_DOMAIN`, `WILDCARD_INSTANCE_DOMAIN`, mixed-case hart entries, and `--remove`
  - regression tests for the new fixes: `HART_URL`/`SERVICE_URL` with multiple trailing slashes, hook `remove` with empty domain, and `cf_upsert` with a record name or content containing quotes/special characters
  - confirm generated Traefik `Host()` / `HostRegexp()` rules and Cloudflare DNS targets are lowercase
- If the gate passes, close PR #25 as superseded and the original objective is resolved. If QA finds a regression or an uncovered edge case, open a focused GitHub issue and produce one small conventional-commit PR.

## 2026-08-13 architect plan (am-add074-dknwwukg17q4-1f14af53)

- `gh issue list --state open` returns `[]`; issues #1, #16, and #17 are CLOSED. No open GitHub issues remain to fix.
- `gh pr list --state open` returns `[]`; PR #26 is MERGED into `origin/master` and no stale open PRs remain.
- The current branch `am/am-add074-dknwwukg17q4-1f14af53` is at the same commit as `origin/master` (`808a600`), which contains all previously landed fixes:
  - fast `HART_DOMAIN_HOOK remove` cleanup and `WILDCARD_INSTANCE_DOMAIN` support,
  - lower-case normalization of hart domains and wildcard inputs,
  - most-specific Cloudflare zone selection,
  - `cf()` curl args array for safe JSON quoting,
  - `cf_upsert()` JSON built with jq,
  - hook remove-argument validation.
- `bash -n hart-domain-sync.sh hart-domain-hook.sh` passes; `shellcheck` is not installed here.
- No additional code change is needed to resolve the current (empty) open issue list.
- QA runs the verification gate:
  - `bash -n hart-domain-sync.sh hart-domain-hook.sh`
  - `shellcheck hart-domain-sync.sh hart-domain-hook.sh` (if installed)
  - manual dry-runs in both directory and file modes covering `WILDCARD_DOMAIN`, `WILDCARD_INSTANCE_DOMAIN`, mixed-case hart entries, `--remove`, and remove with an empty domain
  - regression tests for the robustness fixes now in `origin/master`: multiple trailing slashes on `HART_URL`/`SERVICE_URL`, JSON bodies with spaces/special characters, `zone_for()` with glob-like zone names, and uppercase wildcard inputs
  - confirm generated Traefik `Host()`/`HostRegexp()` rules and Cloudflare DNS targets are lowercase
- If QA finds a regression or an uncovered edge case, open a focused GitHub issue and produce one small conventional-commit PR; otherwise the objective is resolved and no further action is needed.
