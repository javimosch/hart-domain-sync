# hart-domain-sync

Reconciles [hart](https://github.com/javimosch/machin-hart)'s custom-domain mappings into
**Traefik** dynamic config + **Cloudflare** DNS. hart owns the mapping (its `domains` table,
served at `GET /v1/domain`); this turns that desired set into a live proxy + DNS. Separate from
hart on purpose — provisioning stays out of the app (issue machin-hart#16). It consumes hart's
`HART_DOMAIN_HOOK` and/or runs on a timer.

## What it does (each run)

1. Reads the desired domain set from `GET $HART_URL/v1/domain`.
2. For a domain under one of **your own Cloudflare zones** (the whitelist, fetched live each run),
   upserts an `A → $BOX_IP` (and `AAAA → $BOX_IP6`, if set) grey-cloud record. Domains outside your
   zones are logged for the creator to point their own DNS.
3. Writes one Traefik file per domain — `$DEST/hart-<slug>.yml` (a `Host()` router → hart's local
   port, TLS via your cert resolver) in a **watched directory** (hot-reload).
4. If a brand-new domain was added, waits `PROPAGATE_WAIT`s then restarts Traefik once to force a
   clean ACME attempt (see the race note below). Steady-state runs never restart.
5. Prunes `hart-*.yml` files whose mapping was removed — **only after a successful hart fetch**
   (never wipes on an outage). DNS records are left in place on unmap (non-destructive).

**Additive & safe:** only ever touches files named `hart-*.yml` in `$DEST` and A/AAAA records under
your own zones. Never edits other Traefik files, never deletes DNS.

## Triggers

- **`hart-domain-hook.sh`** — set as hart's `HART_DOMAIN_HOOK`; fires a background reconcile the
  instant a domain is mapped/unmapped (returns immediately, doesn't block the HTTP response).
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
| `DEST` | `/etc/traefik/dynamic.d` | Traefik watched directory |
| `SERVICE_URL` | `http://127.0.0.1:8799` | how Traefik reaches hart |
| `ENTRYPOINT` | `websecure` | Traefik TLS entrypoint name |
| `CERT_RESOLVER` | `letsencrypt` | Traefik cert resolver name |
| `CF_ENV` | `/etc/traefik/cloudflare.env` | file holding `CF_API_EMAIL` + `CF_API_KEY` (Cloudflare global key) |
| `MANAGE_DNS` | `1` | `0` = don't touch Cloudflare DNS at all |
| `PROPAGATE_WAIT` | `10` | seconds to wait for DNS before the new-domain Traefik restart |

## Prerequisites

- **Traefik directory provider**: Traefik must watch `$DEST` (`providers.file.directory`). If you run
  a single-file provider today, migrate additively — create the dir, symlink your existing dynamic
  file into it, and repoint the provider (nothing in the existing file changes).
- **Cloudflare global key** in `$CF_ENV` as `CF_API_EMAIL` + `CF_API_KEY` (the same file Traefik's
  DNS challenge uses, if you have one).
- **Passwordless sudo** for the runner user (only used to `systemctl restart traefik` on new domains).
- `curl` + `jq` on the host. Traefik cert resolver reachable (HTTP-01 works for arbitrary domains
  once DNS points at the box).

## Install

```sh
scp hart-domain-sync.sh hart-domain-hook.sh <host>:/opt/hart/
ssh <host> 'chmod +x /opt/hart/hart-domain-sync.sh /opt/hart/hart-domain-hook.sh'
# edit systemd/hart-domain-sync.service (User=, paths) for your host, then:
scp systemd/* <host>:/tmp/ && ssh <host> 'sudo mv /tmp/hart-domain-sync.{service,timer} /etc/systemd/system/ && sudo systemctl daemon-reload'
# write /etc/hart/domain-sync.env with at least BOX_IP=<your-ipv4> (and BOX_IP6 if needed)
# set HART_DOMAIN_HOOK=/opt/hart/hart-domain-hook.sh in hart's env, restart hart
# after the Traefik directory-provider prerequisite is in place:
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
