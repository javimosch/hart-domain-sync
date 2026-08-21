# hart-domain-sync

Reconciles [hart](https://github.com/javimosch/machin-hart)'s custom-domain mappings into
**Traefik** dynamic config + **Cloudflare** DNS. hart owns the mapping (its `domains` table,
served at `GET /v1/domain`); this turns that desired set into a live proxy + DNS. Separate from
hart on purpose — provisioning stays out of the app (issue machin-hart#16). It consumes hart's
`HART_DOMAIN_HOOK` and/or runs on a timer.

## What it does (each run)

1. Reads the desired domain set from `GET $HART_URL/v1/domain` (sends `Authorization: Bearer $HART_ADMIN_TOKEN`
   or `$HART_TOKEN` if either is set, so it works against locked-down hart instances).
2. For a domain under one of **your own Cloudflare zones** (the whitelist, fetched live each run),
   upserts an `A → $BOX_IP` (and `AAAA → $BOX_IP6`, if set) grey-cloud record. Domains outside your
   zones are logged for the creator to point their own DNS.
3. Writes a `Host()` router → hart's local port (TLS via your cert resolver) for each domain, in
   whichever layout your Traefik actually reads — see **Traefik provider modes** below.
4. If `WILDCARD_DOMAIN` is set (e.g. `hart.intrane.fr`), any mapped subdomain of it is handled by a
   single `hart-<slug>-wildcard.yml` with a `HostRegexp(`^.+\.hart\.intrane\.fr$`)` router instead of
   per-domain files/DNS. The reconciler also upserts a `*.WILDCARD_DOMAIN` A/AAAA record when needed.
5. If `WILDCARD_INSTANCE_DOMAIN` is set (e.g. `hart.intrane.fr`), subdomains under it are covered by an
   externally managed wildcard router/DNS and are skipped; they are logged so the operator can see them.
6. If a brand-new domain was added, waits `PROPAGATE_WAIT`s then restarts Traefik once to force a
   clean ACME attempt (see the race note below). Steady-state runs never restart.
7. Prunes `hart-*.yml` files whose mapping was removed — **only after a successful hart fetch**
   (never wipes on an outage). DNS records are left in place on unmap (non-destructive).

**Additive & safe:** only ever touches things named `hart-*` — files in `$DEST` (directory mode) or
those keys inside `$SINGLE_FILE` (file mode) — plus A/AAAA records under your own zones. Never
touches another tool's routers, never deletes DNS.

## Traefik provider modes

Traefik reads dynamic config one of two ways, and writing to the wrong one fails **silently**: the
routers are simply never loaded, so the domain never gets a certificate and just serves Traefik's
self-signed default, with nothing in the logs to say why. So the mode is detected rather than assumed.

| `TRAEFIK_MODE` | matches | what this writes |
|---|---|---|
| `directory` | `providers.file.directory` | one file per domain, `$DEST/hart-<slug>.yml` |
| `file` | `providers.file.filename` | merges `hart-*` routers/services **into** `$SINGLE_FILE` |
| `auto` *(default)* | — | reads `$TRAEFIK_MAIN` and picks whichever it actually uses |

In **file mode** the per-domain files are staged in a tmpdir and only `hart-*` keys are folded
into the single file. Any of our old files left in `$DEST` from a previous directory-mode run are
removed, since a `filename:` Traefik never reads them — they are inert but look exactly like live
config to whoever debugs the next routing problem.

In **file mode** the single file is usually shared with whatever else manages it. The merge therefore
replaces only `hart-*` keys and carries every other entry through byte-identical — it splices text
rather than round-tripping the YAML, so comments and other tools' formatting survive. Writes are
atomic (temp file + rename), so Traefik never sees a half-written file, and the merge is a fixpoint,
so steady-state runs change nothing and trigger no reload.

**A host already routed by someone else is left alone.** Before writing a router, the reconciler
checks the `Host()` rules already claimed by routers it does not own (in the shared file, or in
sibling files in `$DEST`) and skips that domain, naming the owner in the log. Two routers on one
rule is a real misconfiguration — Traefik warns and which one serves is not yours to choose. DNS is
still upserted for skipped domains: the record has to exist either way, the upsert is idempotent,
and it is a useful backstop if the other tool's DNS lapses.

⚠️ File mode is only safe if the *other* writers of that file also preserve entries they do not own.
[hotify](https://github.com/javimosch/hotify-cli) does since its `traefik-dual-mode` change; before
that, its `setup-traefik` regenerated the whole file and would erase these routers on the next run.

## Triggers

- **`hart-domain-hook.sh`** — set as hart's `HART_DOMAIN_HOOK`; fires a background reconcile the
  instant a domain is mapped/unmapped (returns immediately, doesn't block the HTTP response).
  Set `HART_DOMAIN_SYNC` and `HART_DOMAIN_SYNC_LOG` to override the default hook script and log path;
  empty or whitespace-only values fall back to the defaults. If the configured log directory is not
  writable, the hook falls back to `/tmp/hart-domain-sync.log`.
- **`hart-domain-sync.timer`** — every 5 min; self-heals missed hooks, manual DB edits, restarts.

## Config

Set host-specific values in a config file (default `/etc/hart/domain-sync.env`, also loaded by the
systemd unit). The built-in defaults are **generic conventions, not host addresses** — you must at
least set `BOX_IP`.

| var | default | |
|---|---|---|
| `BOX_IP` | *(required for DNS)* | this box's public **IPv4** (A-record target) |
| `BOX_IP6` | *(empty)* | this box's public **IPv6** (AAAA target) — **required if your zone has a proxied wildcard**, see below |
| `HART_URL` | `http://127.0.0.1:8799` | hart daemon |
| `DEST` | `/etc/traefik/dynamic.d` | Traefik watched directory (directory mode) |
| `TRAEFIK_MODE` | `auto` | `auto` \| `directory` \| `file` — see above |
| `TRAEFIK_MAIN` | `/etc/traefik/traefik.yml` | read to auto-detect the mode |
| `SINGLE_FILE` | `/etc/traefik/dynamic.yml` | merge target in file mode |
| `SERVICE_URL` | `http://127.0.0.1:8799` | how Traefik reaches hart |
| `ENTRYPOINT` | `websecure` | Traefik TLS entrypoint name |
| `CERT_RESOLVER` | `letsencrypt` | Traefik cert resolver name |
| `CF_ENV` | `/etc/traefik/cloudflare.env` | file holding `CF_API_EMAIL` + `CF_API_KEY` (Cloudflare global key); supports `export`, whitespace around `=`, quotes, and trailing comments |
| `MANAGE_DNS` | `1` | `0` = don't touch Cloudflare DNS at all |
| `WILDCARD_DOMAIN` | *(empty)* | e.g. `hart.intrane.fr` — subdomains are routed by one `HostRegexp` router instead of per-domain files |
| `WILDCARD_INSTANCE_DOMAIN` | *(empty)* | e.g. `hart.intrane.fr` — subdomains are covered by an externally managed wildcard; skip per-domain files and DNS |
| `HART_ADMIN_TOKEN` / `HART_TOKEN` | *(empty)* | Authorization header for `GET /v1/domain` on locked-down hart instances |
| `PROPAGATE_WAIT` | `10` | seconds to wait for DNS before the new-domain Traefik restart |

Any variable with a default falls back to that default when the env value is empty or
whitespace-only after trimming (including a path padded with trailing spaces or a CRLF).

## Prerequisites

- **A Traefik file provider of either shape** — directory or single file. Both are supported and the
  mode is auto-detected, so no migration is needed. Directory mode is still the cleaner design (no
  shared file, no merge), but it is no longer a prerequisite.
- **Cloudflare global key** in `$CF_ENV` as `CF_API_EMAIL` + `CF_API_KEY` (the same file Traefik's
  DNS challenge uses, if you have one).
- **Passwordless sudo** for the runner user (only used to `systemctl restart traefik` on new domains).
- `curl`, `jq`, and `python3` on the host (file-mode merge and fast remove use inline Python).
  Traefik cert resolver reachable (HTTP-01 works for arbitrary domains once DNS points at the box).

## Install

```sh
scp hart-domain-sync.sh hart-domain-hook.sh <host>:/opt/hart/
ssh <host> 'chmod +x /opt/hart/hart-domain-sync.sh /opt/hart/hart-domain-hook.sh'
# edit systemd/hart-domain-sync.service (User=, paths) for your host, then:
scp systemd/* <host>:/tmp/ && ssh <host> 'sudo mv /tmp/hart-domain-sync.{service,timer} /etc/systemd/system/ && sudo systemctl daemon-reload'
# write /etc/hart/domain-sync.env with at least BOX_IP=<your-ipv4> (and BOX_IP6 if needed)
# set HART_DOMAIN_HOOK=/opt/hart/hart-domain-hook.sh in hart's env, restart hart
ssh <host> 'sudo systemctl enable --now hart-domain-sync.timer'
```

## Gotcha: proxied wildcards force dual-stack (A **and** AAAA)

If a zone has a **proxied wildcard** (`*.example.com` orange-cloud → Cloudflare), Cloudflare
synthesizes an **AAAA (IPv6)** answer for any subdomain under it — even one where you added an
explicit grey **A** record. Let's Encrypt prefers IPv6, so it validates the ACME HTTP-01 challenge
against **Cloudflare** (which 404s the challenge) instead of your box → the cert never issues and the
domain serves only Traefik's default (invalid) cert.

Fix: set **`BOX_IP6`** to the box's public IPv6 so the reconciler also writes an explicit grey
**AAAA → your box**, shadowing the wildcard's synthesized IPv6. Then LE validates against the box on
both stacks. Requires public IPv6 on the box and Traefik listening on it (it binds `*:80/:443` =
dual-stack by default).

## Gotcha: ACME race on new domains (handled automatically)

Traefik hot-loads a new `hart-*.yml` router the instant it appears and attempts ACME **immediately** —
often before the just-created DNS has propagated, so that first attempt validates against the stale
answer and Traefik backs off. The reconciler handles this: it sets DNS **first**, and when a brand-new
router file is created it waits `PROPAGATE_WAIT`s then runs `sudo systemctl restart traefik` once to
force a clean retry with correct DNS. Steady-state reconciles never restart.
