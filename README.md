# hart-domain-sync

Reconciles [hart](https://github.com/javimosch/machin-hart)'s custom-domain mappings into
**Traefik** dynamic config + **Cloudflare** DNS. hart owns the mapping (its `domains` table,
served at `GET /v1/domain`); this turns that desired set into a live proxy + DNS. Separate from
hart on purpose — provisioning stays out of the app (issue machin-hart#16).

## What it does (each run)

1. Reads the desired domain set from `GET $HART_URL/v1/domain`.
2. Writes one Traefik file per domain — `$DEST/hart-<slug>.yml` (a `Host()` router → hart's local
   port, TLS via your cert resolver) in a **watched directory** (hot-reload).
3. For a domain under one of **your own Cloudflare zones** (the whitelist, fetched live each run),
   upserts an `A → $BOX_IP` record (grey-cloud). Domains outside your zones are logged for the
   creator to point themselves.
4. Prunes `hart-*.yml` files whose mapping was removed — **only after a successful hart fetch**
   (never wipes on an outage). DNS records are left in place on unmap (non-destructive).

**Additive & safe:** only ever touches files named `hart-*.yml` in `$DEST` and A-records under your
zones. Never edits other Traefik files, never deletes DNS.

## Triggers

- **`hart-domain-hook.sh`** — set as hart's `HART_DOMAIN_HOOK`; fires a background reconcile the
  instant a domain is mapped/unmapped (returns immediately, doesn't block the HTTP response).
- **`hart-domain-sync.timer`** — every 5 min; self-heals missed hooks, manual DB edits, restarts.

## Config (env, all optional — sane dk1 defaults)

| var | default | |
|---|---|---|
| `HART_URL` | `http://127.0.0.1:8799` | hart daemon |
| `DEST` | `/etc/traefik/dynamic.d` | Traefik watched dir |
| `BOX_IP` | `92.113.145.178` | A-record target |
| `SERVICE_URL` | `http://127.0.0.1:8799` | Traefik → hart backend |
| `ENTRYPOINT` | `websecure` | Traefik TLS entrypoint |
| `CERT_RESOLVER` | `letsencrypt` | Traefik cert resolver (HTTP-01 on dk1) |
| `CF_ENV` | `/etc/traefik/cloudflare.env` | source of `CF_API_EMAIL`/`CF_API_KEY` |
| `MANAGE_DNS` | `1` | set `0` to disable CF DNS entirely |

Override on dk1 via `/etc/hart/domain-sync.env` (read by the systemd unit).

## Prerequisite: Traefik directory provider

Traefik must watch `$DEST`. On dk1 (single-file provider today) this is a one-time additive
migration — see the deploy notes; the existing `dynamic.yml` is symlinked in untouched and only the
provider pointer changes.

## Install (dk1)

```sh
scp hart-domain-sync.sh hart-domain-hook.sh dk1:/opt/hart/
ssh dk1 'chmod +x /opt/hart/hart-domain-sync.sh /opt/hart/hart-domain-hook.sh'
scp systemd/* dk1:/tmp/ && ssh dk1 'sudo mv /tmp/hart-domain-sync.{service,timer} /etc/systemd/system/ && sudo systemctl daemon-reload'
# set HART_DOMAIN_HOOK=/opt/hart/hart-domain-hook.sh in /etc/hart/hart.env, restart hart
# after the Traefik directory-provider migration: sudo systemctl enable --now hart-domain-sync.timer
```

Requires `curl` + `jq` on the host.
