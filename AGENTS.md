# Agent Notes: hart-domain-sync

## Project type
Pure bash utility (curl + jq + python3) that reconciles hart custom domains into
Traefik dynamic config and Cloudflare DNS. No package manager, build step, or
configured test runner.

## Key files
- `hart-domain-sync.sh` — main reconcile script (DNS + Traefik directory or single-file mode).
- `hart-domain-hook.sh` — `HART_DOMAIN_HOOK` target that fires the sync in the background.
- `README.md` — operator-facing docs.
- `systemd/hart-domain-sync.{service,timer}` — systemd units.

## Current objective
Fix issue #1: fast `HART_DOMAIN_HOOK remove` cleanup + `WILDCARD_INSTANCE_DOMAIN`
support so externally-managed wildcard subdomains are skipped.

## Open PR awareness
PRs #2, #3, and #4 already attempt overlapping changes for issue #1, and PR #5
adds partial docs/notes. New work must implement from the current base
(`origin/master`) and not rely on those unmerged branches.

## Plan
1. `hart-domain-sync.sh`
   - Add `WILDCARD_INSTANCE_DOMAIN` env var (default empty).
   - Add `under_wildcard_instance()` helper: true only for strict subdomains of
     `WILDCARD_INSTANCE_DOMAIN`.
   - In the per-domain loop, skip Traefik files and DNS upserts for any domain
     under `WILDCARD_INSTANCE_DOMAIN`.
   - Refactor `TRAEFIK_MODE=auto` detection into `resolve_traefik_mode()` so the
     `--remove` path can use it before fetching from hart.
   - Add a fast `--remove <domain>` path at the top of the script:
     - Resolve the Traefik mode.
     - If the domain is under `WILDCARD_DOMAIN` or `WILDCARD_INSTANCE_DOMAIN`,
       log and exit.
     - In directory mode, remove `hart-<slug>.yml` from `DEST`.
     - In file mode, remove the `hart-<slug>` router and service from
       `SINGLE_FILE` using the same text-splicing pattern the merge uses.
     - Do not require a successful hart fetch. Do not touch DNS.
2. `hart-domain-hook.sh`
   - Parse `EVENT` and `DOMAIN` from hart.
   - `add`/`set` (or any non-remove event) → full background reconcile.
   - `remove` with a domain → background `hart-domain-sync.sh --remove <domain>`.
3. `README.md`
   - Add `WILDCARD_INSTANCE_DOMAIN` to the config table.
   - Update "What it does" and "Triggers" sections.
4. `systemd/hart-domain-sync.service`
   - Add `WILDCARD_INSTANCE_DOMAIN` to the commented `EnvironmentFile` list.

## Verification
There is no configured test harness. Before any PR, run:
- `bash -n hart-domain-sync.sh hart-domain-hook.sh`
- `shellcheck hart-domain-sync.sh hart-domain-hook.sh` (if installed)
- Manual dry-run in a temp `DEST` / `SINGLE_FILE`:
  - set `WILDCARD_INSTANCE_DOMAIN=hart.intrane.fr`
  - map `foo.hart.intrane.fr` and `example.com`
  - confirm only `example.com` gets a per-domain file
  - call `--remove example.com` and confirm the file is removed
  - test file mode with `TRAEFIK_MODE=file` and a temp `SINGLE_FILE`
- The final fix commit should contain `Fixes #1`.

## Conventions
- Do not commit `.devin/`, `.claude/`, or `.am-summary` files.
- Use Conventional Commits; reference `Fixes #1` when the change resolves that issue.
