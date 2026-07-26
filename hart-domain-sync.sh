#!/usr/bin/env bash
# hart-domain-sync — reconcile hart's custom-domain mappings into Traefik + Cloudflare DNS.
#
# hart is the source of truth (its `domains` table, read via GET /v1/domain). This turns that
# desired set into:
#   1. one Traefik dynamic-config file per domain in a WATCHED DIRECTORY (hot-reload), and
#   2. a Cloudflare A record -> the box IP, but ONLY for domains under a zone you own (the
#      whitelist is your live CF zone list, fetched each run). Domains outside your zones are
#      the creator's DNS responsibility and are logged, not touched.
#
# ADDITIVE & SAFE: it only ever writes/removes files named "$PREFIX"*.yml in $DEST, and only ever
# upserts A/AAAA records for hostnames under your own zones. It never edits any other Traefik file
# and never deletes DNS. If it cannot reach hart, it aborts WITHOUT pruning (never wipes on outage).
#
# Run as a user that owns $DEST and can read $CF_ENV. Idempotent — safe to run on a timer and from
# hart's HART_DOMAIN_HOOK. Needs: curl, jq. Set host-specific values (BOX_IP, BOX_IP6, ...) in the
# config file below — the built-in defaults are generic conventions, NOT host addresses.
set -uo pipefail

# Config file (also loaded by the systemd unit's EnvironmentFile) — sourced here too so the
# HART_DOMAIN_HOOK path gets the same settings as the timer. Simple KEY=value, operator-owned.
CONF="${DOMAIN_SYNC_ENV:-/etc/hart/domain-sync.env}"
[ -f "$CONF" ] && . "$CONF"

HART_URL="${HART_URL:-http://127.0.0.1:8799}"   # hart daemon (default local)
DEST="${DEST:-/etc/traefik/dynamic.d}"          # Traefik watched directory
BOX_IP="${BOX_IP:-}"                            # REQUIRED for DNS: this box's public IPv4 (A target)
BOX_IP6="${BOX_IP6:-}"                          # this box's public IPv6 (AAAA target) — set if your zone has a proxied wildcard
SERVICE_URL="${SERVICE_URL:-http://127.0.0.1:8799}"   # how Traefik reaches hart
ENTRYPOINT="${ENTRYPOINT:-websecure}"           # Traefik TLS entrypoint name
CERT_RESOLVER="${CERT_RESOLVER:-letsencrypt}"   # Traefik cert resolver name
CF_ENV="${CF_ENV:-/etc/traefik/cloudflare.env}" # file holding CF_API_EMAIL + CF_API_KEY
MANAGE_DNS="${MANAGE_DNS:-1}"                   # 0 = don't touch Cloudflare DNS at all
WILDCARD_DOMAIN="${WILDCARD_DOMAIN:-}"          # e.g. hart.intrane.fr — write one Host(\`*.hart.intrane.fr\`) router for all subdomains
PREFIX="hart-"
AUTH_TOKEN="${HART_ADMIN_TOKEN:-${HART_TOKEN:-}}"  # send Authorization if the hart instance requires a token

if [ "$MANAGE_DNS" = "1" ] && [ -z "$BOX_IP" ]; then
  log_early() { echo "$(date -u +%H:%M:%S) [hart-domain-sync] $*" >&2; }
  log_early "MANAGE_DNS=1 but BOX_IP is unset — set BOX_IP (this box's public IPv4) in $CONF, or MANAGE_DNS=0. Skipping DNS."
  MANAGE_DNS=0
fi

log() { echo "$(date -u +%H:%M:%S) [hart-domain-sync] $*" >&2; }

# CF creds: extract (don't source — env files can carry chars bash chokes on).
cf_val() { grep -i "^$1=" "$CF_ENV" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'"' ' | tr -d "'"; }
CF_EMAIL="$(cf_val CF_API_EMAIL)"
CF_KEY="$(cf_val CF_API_KEY)"

cf() { # cf <METHOD> <path> [json-body]
  local m="$1" p="$2" d="${3:-}"
  curl -s --max-time 15 -X "$m" "https://api.cloudflare.com/client/v4$p" \
    -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" \
    -H "Content-Type: application/json" ${d:+--data "$d"}
}

slug() { printf '%s' "$1" | tr 'A-Z' 'a-z' | tr '.' '-' | tr -cd 'a-z0-9-'; }
regex_escape() { printf '%s' "$1" | sed 's/\./\\./g'; }

under_wildcard() { # true if $1 is a subdomain (or the same host) of $WILDCARD_DOMAIN
  [ -n "$WILDCARD_DOMAIN" ] || return 1
  [ "$1" = "$WILDCARD_DOMAIN" ] && return 0
  case "$1" in *".$WILDCARD_DOMAIN") return 0 ;; esac
  return 1
}

# --- 1. desired set from hart (abort without pruning if unreachable) ---
CURL_AUTH=()
[ -n "$AUTH_TOKEN" ] && CURL_AUTH=("-H" "Authorization: Bearer $AUTH_TOKEN")
RESP="$(curl -s --max-time 10 "${CURL_AUTH[@]}" "$HART_URL/v1/domain")" \
  || { log "cannot reach hart at $HART_URL — abort (no prune)"; exit 1; }
echo "$RESP" | jq -e '.ok==true' >/dev/null 2>&1 \
  || { log "unexpected hart response — abort (no prune): $(printf '%.120s' "$RESP")"; exit 1; }
mapfile -t DOMAINS < <(echo "$RESP" | jq -r '.domains[]?.domain' | grep -E '^[a-z0-9.-]+$' || true)

mkdir -p "$DEST" 2>/dev/null || { log "cannot create $DEST (run the Traefik directory-provider migration first)"; exit 1; }

# --- 2. CF zones = the DNS whitelist (best-effort; DNS skipped if this fails) ---
ZONES=()
if [ "$MANAGE_DNS" = "1" ] && [ -n "$CF_EMAIL" ] && [ -n "$CF_KEY" ]; then
  ZRESP="$(cf GET '/zones?per_page=50&status=active')"
  if echo "$ZRESP" | jq -e '.success==true' >/dev/null 2>&1; then
    mapfile -t ZONES < <(echo "$ZRESP" | jq -r '.result[].name')
    log "CF zones (whitelist): ${#ZONES[@]}"
  else
    log "CF zones fetch failed — DNS automation skipped this run"
  fi
fi

zone_for() { # echo the whitelist zone that is a suffix of $1, else nothing
  local d="$1" z
  for z in "${ZONES[@]}"; do
    if [ "$d" = "$z" ] || [ "${d%.$z}" != "$d" ]; then printf '%s' "$z"; return; fi
  done
}

cf_upsert() { # cf_upsert <fqdn> <zone> <type> <content>
  local d="$1" z="$2" t="$3" c="$4" zid rid body
  zid="$(cf GET "/zones?name=$z" | jq -r '.result[0].id // empty')"
  [ -n "$zid" ] || { log "DNS: no zone id for $z"; return; }
  body="{\"type\":\"$t\",\"name\":\"$d\",\"content\":\"$c\",\"ttl\":120,\"proxied\":false}"
  rid="$(cf GET "/zones/$zid/dns_records?type=$t&name=$d" | jq -r '.result[0].id // empty')"
  if [ -n "$rid" ]; then
    cf PUT "/zones/$zid/dns_records/$rid" "$body" | jq -e '.success==true' >/dev/null 2>&1 \
      && log "DNS: $t $d -> $c (updated)" || log "DNS: $t update failed for $d"
  else
    cf POST "/zones/$zid/dns_records" "$body" | jq -e '.success==true' >/dev/null 2>&1 \
      && log "DNS: $t $d -> $c (created)" || log "DNS: $t create failed for $d"
  fi
}

# --- 3. per domain: DNS FIRST (so it can propagate), then the router file ---
# Traefik hot-loads a new router file the instant it appears and attempts ACME immediately; if DNS
# hasn't propagated yet that first attempt fails and Traefik backs off. So we set DNS before writing
# the file, and if any brand-NEW router file was created we force one Traefik restart at the end
# (after a short propagation wait) to trigger a clean ACME retry. Established domains never restart.
declare -A WANT=()
NEW=0
NEEDS_WILDCARD=0
for d in "${DOMAINS[@]}"; do
  [ -n "$d" ] || continue
  if under_wildcard "$d"; then
    NEEDS_WILDCARD=1
    log "wildcard: $d -> *.$WILDCARD_DOMAIN (skipping per-domain Traefik/DNS)"
    continue
  fi
  s="$(slug "$d")"
  WANT["$PREFIX$s.yml"]=1
  f="$DEST/$PREFIX$s.yml"
  if [ "$MANAGE_DNS" = "1" ]; then
    z="$(zone_for "$d")"
    if [ -n "$z" ]; then
      cf_upsert "$d" "$z" A "$BOX_IP"
      [ -n "$BOX_IP6" ] && cf_upsert "$d" "$z" AAAA "$BOX_IP6"
    else log "DNS: $d is not under one of your zones — create 'A $d -> $BOX_IP' at the domain's registrar"; fi
  fi
  existed=0; [ -e "$f" ] && existed=1
  tmp="$(mktemp)"
  cat > "$tmp" <<YAML
# managed by hart-domain-sync — regenerated, do not edit. domain: $d
http:
  routers:
    hart-$s:
      rule: "Host(\`$d\`)"
      entryPoints: [$ENTRYPOINT]
      service: hart-$s
      tls:
        certResolver: $CERT_RESOLVER
  services:
    hart-$s:
      loadBalancer:
        servers:
          - url: "$SERVICE_URL"
YAML
  if ! cmp -s "$tmp" "$f" 2>/dev/null; then mv "$tmp" "$f"; chmod 644 "$f"; log "router: $PREFIX$s.yml written ($d)"; [ "$existed" = 0 ] && NEW=1; else rm -f "$tmp"; fi
done

# --- 4. wildcard instance router (one router for *.WILDCARD_DOMAIN) ---
if [ -n "$WILDCARD_DOMAIN" ] && [ "$NEEDS_WILDCARD" = "1" ]; then
  WILD_SLUG="$(slug "$WILDCARD_DOMAIN")"
  WILDCARD_FILE="${PREFIX}${WILD_SLUG}-wildcard.yml"
  WANT["$WILDCARD_FILE"]=1
  wf="$DEST/$WILDCARD_FILE"
  REGEX="$(regex_escape "$WILDCARD_DOMAIN")"
  existed=0; [ -e "$wf" ] && existed=1
  tmp="$(mktemp)"
  cat > "$tmp" <<YAML
# managed by hart-domain-sync — wildcard router for *.$WILDCARD_DOMAIN
http:
  routers:
    hart-${WILD_SLUG}-wildcard:
      rule: "HostRegexp(\`^.+\\.$REGEX$\`)"
      entryPoints: [$ENTRYPOINT]
      service: hart-$WILD_SLUG
      tls:
        certResolver: $CERT_RESOLVER
  services:
    hart-$WILD_SLUG:
      loadBalancer:
        servers:
          - url: "$SERVICE_URL"
YAML
  if ! cmp -s "$tmp" "$wf" 2>/dev/null; then mv "$tmp" "$wf"; chmod 644 "$wf"; log "router: $WILDCARD_FILE written (wildcard for *.$WILDCARD_DOMAIN)"; [ "$existed" = 0 ] && NEW=1; else rm -f "$tmp"; fi
  if [ "$MANAGE_DNS" = "1" ]; then
    z="$(zone_for "*.$WILDCARD_DOMAIN")"
    if [ -n "$z" ]; then
      cf_upsert "*.$WILDCARD_DOMAIN" "$z" A "$BOX_IP"
      [ -n "$BOX_IP6" ] && cf_upsert "*.$WILDCARD_DOMAIN" "$z" AAAA "$BOX_IP6"
    else log "DNS: *.$WILDCARD_DOMAIN is not under one of your zones — create the wildcard A record at your registrar"; fi
  fi
fi

# --- 5. prune orphaned router files (reached only after a successful hart fetch) ---
# DNS records are intentionally left in place on unmap (non-destructive; harmless if the domain returns).
shopt -s nullglob
for f in "$DEST/$PREFIX"*.yml; do
  b="$(basename "$f")"
  if [ -z "${WANT[$b]:-}" ]; then rm -f "$f"; log "pruned: $b (mapping removed)"; fi
done
shopt -u nullglob

# --- 5. new domain(s) -> force one clean ACME attempt (DNS has been set + given time to propagate) ---
if [ "$NEW" = 1 ]; then
  log "new domain(s) added — waiting ${PROPAGATE_WAIT:-10}s for DNS, then restarting Traefik for ACME"
  sleep "${PROPAGATE_WAIT:-10}"
  if sudo -n systemctl restart traefik 2>/dev/null; then
    log "traefik restarted — cert(s) will issue on the retry"
  else
    log "WARN: could not restart traefik (needs passwordless sudo) — new cert issues on the next restart"
  fi
fi

log "reconcile complete: ${#DOMAINS[@]} domain(s)"
