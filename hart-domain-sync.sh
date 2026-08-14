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
# ADDITIVE & SAFE: it only ever touches keys named "$PREFIX"* — files in $DEST (directory mode)
# or those keys inside $SINGLE_FILE (file mode, everything else preserved verbatim) — and only ever
# upserts A/AAAA records for hostnames under your own zones. It never edits any other Traefik file
# and never deletes DNS. If it cannot reach hart, it aborts WITHOUT pruning (never wipes on outage).
#
# Run as a user that owns $DEST and can read $CF_ENV. Idempotent — safe to run on a timer and from
# hart's HART_DOMAIN_HOOK. Needs: curl, jq. Set host-specific values (BOX_IP, BOX_IP6, ...) in the
# config file below — the built-in defaults are generic conventions, NOT host addresses.
set -uo pipefail

trim() { printf '%s' "$1" | LC_ALL=C tr -d '\r' | LC_ALL=C sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

# Config file (also loaded by the systemd unit's EnvironmentFile) — sourced here too so the
# HART_DOMAIN_HOOK path gets the same settings as the timer. Simple KEY=value, operator-owned.
CONF="${DOMAIN_SYNC_ENV:-/etc/hart/domain-sync.env}"
CONF="$(trim "$CONF")"
# shellcheck source=/dev/null
[ -f "$CONF" ] && . "$CONF"

HART_URL="${HART_URL:-http://127.0.0.1:8799}"   # hart daemon (default local)
DEST="${DEST:-/etc/traefik/dynamic.d}"          # Traefik watched directory (directory mode)
DEST="$(trim "$DEST")"
# TRAEFIK_MODE: how this box's Traefik reads dynamic config.
#   directory -> providers.file.directory : we drop one router file per domain in $DEST
#   file      -> providers.file.filename  : we MERGE our routers into that single file
#   auto      -> read TRAEFIK_MAIN and pick whichever it actually uses (default)
# This exists because a `filename:` Traefik never reads $DEST, so on such a box every
# router written here is silently ignored and the domain never gets a certificate --
# it just serves Traefik's self-signed default, with nothing in the logs.
TRAEFIK_MODE="${TRAEFIK_MODE:-auto}"
TRAEFIK_MODE="$(trim "$TRAEFIK_MODE")"
[ -n "$TRAEFIK_MODE" ] || TRAEFIK_MODE=auto
TRAEFIK_MAIN="${TRAEFIK_MAIN:-/etc/traefik/traefik.yml}"
TRAEFIK_MAIN="$(trim "$TRAEFIK_MAIN")"
SINGLE_FILE="${SINGLE_FILE:-/etc/traefik/dynamic.yml}"   # target in file mode
SINGLE_FILE="$(trim "$SINGLE_FILE")"
BOX_IP="${BOX_IP:-}"                            # REQUIRED for DNS: this box's public IPv4 (A target)
BOX_IP6="${BOX_IP6:-}"                          # this box's public IPv6 (AAAA target) — set if your zone has a proxied wildcard
BOX_IP="$(trim "$BOX_IP")"
BOX_IP6="$(trim "$BOX_IP6")"
SERVICE_URL="${SERVICE_URL:-http://127.0.0.1:8799}"   # how Traefik reaches hart
# Remove any trailing slashes so the hart API call doesn't end up with a doubled
# (or tripled) path separator, and the Traefik upstream URL is always a clean URL.
HART_URL="$(trim "$HART_URL")"
SERVICE_URL="$(trim "$SERVICE_URL")"
while [[ "$HART_URL" == */ ]]; do HART_URL="${HART_URL%/}"; done
while [[ "$SERVICE_URL" == */ ]]; do SERVICE_URL="${SERVICE_URL%/}"; done
ENTRYPOINT="${ENTRYPOINT:-websecure}"           # Traefik TLS entrypoint name
ENTRYPOINT="$(trim "$ENTRYPOINT")"
[ -n "$ENTRYPOINT" ] || ENTRYPOINT=websecure
CERT_RESOLVER="${CERT_RESOLVER:-letsencrypt}"   # Traefik cert resolver name
CERT_RESOLVER="$(trim "$CERT_RESOLVER")"
[ -n "$CERT_RESOLVER" ] || CERT_RESOLVER=letsencrypt
CF_ENV="${CF_ENV:-/etc/traefik/cloudflare.env}" # file holding CF_API_EMAIL + CF_API_KEY
CF_ENV="$(trim "$CF_ENV")"
MANAGE_DNS="${MANAGE_DNS:-1}"                   # 0 = don't touch Cloudflare DNS at all
MANAGE_DNS="$(trim "$MANAGE_DNS")"
# Seconds to wait for new DNS records to propagate before restarting Traefik for ACME.
PROPAGATE_WAIT="${PROPAGATE_WAIT:-10}"
PROPAGATE_WAIT="$(trim "$PROPAGATE_WAIT")"
[ -n "$PROPAGATE_WAIT" ] || PROPAGATE_WAIT=10
WILDCARD_DOMAIN="${WILDCARD_DOMAIN:-}"          # e.g. hart.intrane.fr — write one Host(\`*.hart.intrane.fr\`) router for all subdomains
WILDCARD_INSTANCE_DOMAIN="${WILDCARD_INSTANCE_DOMAIN:-}"  # e.g. hart.intrane.fr — subdomains are covered by an external wildcard router/DNS; skip per-domain files
PREFIX="hart-"
REAL_DEST="$DEST"                               # original destination, even if file mode stages elsewhere
AUTH_TOKEN="${HART_ADMIN_TOKEN:-${HART_TOKEN:-}}"  # send Authorization if the hart instance requires a token
AUTH_TOKEN="$(trim "$AUTH_TOKEN")"

# DNS/HTTP hostnames are case-insensitive; normalise wildcard inputs so
# mixed-case hart domains still match the configured wildcard.
WILDCARD_DOMAIN="$(trim "$WILDCARD_DOMAIN" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
WILDCARD_INSTANCE_DOMAIN="$(trim "$WILDCARD_INSTANCE_DOMAIN" | LC_ALL=C tr '[:upper:]' '[:lower:]')"

if [ "$MANAGE_DNS" = "1" ] && [ -z "$BOX_IP" ]; then
  log_early() { echo "$(date -u +%H:%M:%S) [hart-domain-sync] $*" >&2; }
  log_early "MANAGE_DNS=1 but BOX_IP is unset — set BOX_IP (this box's public IPv4) in $CONF, or MANAGE_DNS=0. Skipping DNS."
  MANAGE_DNS=0
fi

log() { echo "$(date -u +%H:%M:%S) [hart-domain-sync] $*" >&2; }

# Optional CLI mode: --remove <domain> (called by HART_DOMAIN_HOOK on removal).
# It runs before any hart/CF I/O and exits after deleting the per-domain config.
REMOVE_DOMAIN=""
if [ "${1:-}" = "--remove" ]; then
  REMOVE_DOMAIN="${2:-}"
  [ -n "$REMOVE_DOMAIN" ] || { log "usage: $0 [--remove <domain>]"; exit 1; }
  # DNS/HTTP hostnames are case-insensitive; keep the remove path consistent
  # with the lower-cased per-domain files generated in the reconcile loop.
  REMOVE_DOMAIN="$(trim "$REMOVE_DOMAIN" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
fi

# CF creds: extract (don't source — env files can carry chars bash chokes on).
# Tolerates optional "export" prefix, whitespace around "=", leading/trailing
# quotes, embedded spaces and any "=" inside the value, and shell-style trailing
# comments outside of quoted strings.
strip_env_comment() {
  local s="$1" c in_quote="" out=""
  for (( i=0; i<${#s}; i++ )); do
    c="${s:$i:1}"
    if [ -n "$in_quote" ]; then
      [ "$c" = "$in_quote" ] && in_quote=""
      out="$out$c"
      continue
    fi
    if [ "$c" = '"' ] || [ "$c" = "'" ]; then
      in_quote="$c"; out="$out$c"; continue
    fi
    [ "$c" = "#" ] && break
    out="$out$c"
  done
  printf '%s' "$out"
}

cf_val() {
  local key="$1" line value
  [ -f "$CF_ENV" ] || return
  line=$(grep -i "^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}${key}[[:space:]]*=" "$CF_ENV" 2>/dev/null | head -1) || true
  [ -n "$line" ] || return
  line="$(printf '%s' "$line" | LC_ALL=C tr -d '\r')"
  value="${line#*=}"
  value="$(strip_env_comment "$value")"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  value="${value#\"}"; value="${value%\"}"
  value="${value#\'}"; value="${value%\'}"
  # CRLF-padded env files can leave carriage returns inside quoted values; strip them.
  value="${value//$'\r'/}"
  printf '%s\n' "$value"
}
CF_EMAIL="$(cf_val CF_API_EMAIL)"
CF_KEY="$(cf_val CF_API_KEY)"

cf() { # cf <METHOD> <path> [json-body]
  local m="$1" p="$2" d="${3:-}"
  local -a args=(-s --max-time 15 -X "$m" "https://api.cloudflare.com/client/v4$p" \
    -H "X-Auth-Email: $CF_EMAIL" -H "X-Auth-Key: $CF_KEY" \
    -H "Content-Type: application/json")
  [ -n "$d" ] && args+=(--data "$d")
  curl "${args[@]}"
}

slug() { printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' | tr '.' '-' | LC_ALL=C tr -cd 'a-z0-9-'; }
regex_escape() { printf '%s' "$1" | sed 's/\./\\\\./g'; }

fast_remove() { # fast_remove <domain>: delete the per-domain router without fetching hart
  local domain="$1" s f key changed
  s="${PREFIX}$(slug "$domain").yml"
  if [ "$TRAEFIK_MODE" = "file" ]; then
    key="${PREFIX}$(slug "$domain")"
    [ -w "$SINGLE_FILE" ] || [ -w "$(dirname "$SINGLE_FILE")" ] \
      || { log "cannot write $SINGLE_FILE — abort"; exit 1; }
    changed=$(TARGET="$SINGLE_FILE" PREFIX="$PREFIX" KEY="$key" python3 - <<'PYREM'
import os, sys, tempfile
target, key = os.environ["TARGET"], os.environ["KEY"]
try:
    text = open(target).read()
except FileNotFoundError:
    print("0"); sys.exit(0)
sections = ("routers", "services", "middlewares")
out, section, skip, changed = [], None, False, False
for line in text.split("\n"):
    t = line.strip()
    indent = len(line) - len(line.lstrip(" "))
    if indent == 2 and t.endswith(":") and not t.startswith("-"):
        section = t[:-1]
        skip = False
        out.append(line)
        continue
    if section in sections and indent == 4 and t.endswith(":") and " " not in t:
        if t[:-1] == key:
            skip = True
            changed = True
            continue
        skip = False
    if not skip:
        out.append(line)
if not changed:
    print("0"); sys.exit(0)
out = "\n".join(out)
d = os.path.dirname(target) or "."
fd, tmp = tempfile.mkstemp(dir=d, prefix=".hart-remove.")
with os.fdopen(fd, "w") as fh: fh.write(out)
os.chmod(tmp, 0o644)
os.replace(tmp, target)
print("1")
PYREM
) || { log "remove from $SINGLE_FILE FAILED — left untouched"; exit 1; }
    if [ "$changed" = "1" ]; then
      log "removed: $key from $SINGLE_FILE (fast remove for $domain)"
    else
      log "remove: $key not found in $SINGLE_FILE (fast remove for $domain)"
    fi
  else
    f="$DEST/$s"
    if [ -e "$f" ]; then
      if rm -f "$f"; then
        log "removed: $s (fast remove for $domain)"
      else
        log "WARN: failed to remove $s"
      fi
    else
      log "remove: $s not present (fast remove for $domain)"
    fi
  fi

  # In file mode, an inert per-domain file may still be sitting in the watched directory
  # from a previous directory-mode run; clean it up so the remove is complete.
  if [ "$TRAEFIK_MODE" = "file" ] && [ -n "$REAL_DEST" ] && [ -e "$REAL_DEST/$s" ]; then
    if rm -f "$REAL_DEST/$s"; then
      log "removed: stale $s from $REAL_DEST (fast remove for $domain)"
    else
      log "WARN: failed to remove stale $s from $REAL_DEST"
    fi
  fi

  log "fast remove complete: $domain"
}

under_wildcard() { # true if $1 is a strict subdomain of $WILDCARD_DOMAIN
  [ -n "$WILDCARD_DOMAIN" ] || return 1
  case "$1" in *".${WILDCARD_DOMAIN}") return 0 ;; esac
  return 1
}

under_wildcard_instance() { # true if $1 is a strict subdomain of $WILDCARD_INSTANCE_DOMAIN (external wildcard)
  [ -n "$WILDCARD_INSTANCE_DOMAIN" ] || return 1
  case "$1" in *".${WILDCARD_INSTANCE_DOMAIN}") return 0 ;; esac
  return 1
}

# resolve the provider layout before touching anything
if [ "$TRAEFIK_MODE" = "auto" ]; then
  if [ -r "$TRAEFIK_MAIN" ] && awk '/^[[:space:]]*#/{next} /^providers:/{p=1} p&&/^[[:space:]]+file:/{f=1} f&&/^[[:space:]]*directory:/{print "d";exit} f&&/^[[:space:]]*filename:/{print "f";exit}' "$TRAEFIK_MAIN" | grep -q d; then
    TRAEFIK_MODE="directory"
  else
    TRAEFIK_MODE="file"
  fi
  log "traefik mode: $TRAEFIK_MODE (detected from $TRAEFIK_MAIN)"
fi

# Fast remove path for HART_DOMAIN_HOOK remove events: no hart fetch needed.
if [ -n "$REMOVE_DOMAIN" ]; then
  fast_remove "$REMOVE_DOMAIN"
  exit 0
fi

# --- 1. desired set from hart (abort without pruning if unreachable) ---
CURL_AUTH=()
[ -n "$AUTH_TOKEN" ] && CURL_AUTH=("-H" "Authorization: Bearer $AUTH_TOKEN")
RESP="$(curl -s --max-time 10 "${CURL_AUTH[@]}" "$HART_URL/v1/domain")" \
  || { log "cannot reach hart at $HART_URL — abort (no prune)"; exit 1; }
echo "$RESP" | jq -e '.ok==true' >/dev/null 2>&1 \
  || { log "unexpected hart response — abort (no prune): $(printf '%.120s' "$RESP")"; exit 1; }
mapfile -t DOMAINS < <(echo "$RESP" | jq -r '.domains[]?.domain' | LC_ALL=C tr '[:upper:]' '[:lower:]' | LC_ALL=C grep -E '^[a-z0-9.-]+$' || true)

# In file mode the per-domain files are only an intermediate representation: generate
# them into a scratch dir with the existing logic, then merge into $SINGLE_FILE. That
# keeps one code path for building routers (incl. the wildcard) and prune semantics.
STAGE=""; REAL_DEST="$DEST"
if [ "$TRAEFIK_MODE" = "file" ]; then
  STAGE="$(mktemp -d)"; DEST="$STAGE"
  trap 'rm -rf "$STAGE"' EXIT
  [ -w "$SINGLE_FILE" ] || [ -w "$(dirname "$SINGLE_FILE")" ] \
    || { log "cannot write $SINGLE_FILE — abort"; exit 1; }

  # A box that ran this script in directory mode before (or was switched to file mode)
  # still has our old per-domain files sitting in $REAL_DEST. Traefik in file mode reads
  # NOTHING from there, so they are inert -- but they look exactly like live config to
  # the next person debugging a routing problem. Since we are no longer writing to that
  # directory, nothing else would ever clean them up, so do it here.
  if [ -d "$REAL_DEST" ]; then
    stale=0
    for f in "$REAL_DEST/$PREFIX"*.yml; do
      [ -e "$f" ] || continue
      rm -f "$f" && stale=$((stale+1))
    done
    [ "$stale" -gt 0 ] && log "removed $stale inert router file(s) from $REAL_DEST (file mode reads $SINGLE_FILE only)"
  fi
fi

# Host() rules already claimed by a router we do not own. Writing a second router for the
# same rule is a real misconfiguration -- Traefik warns and which one serves is not ours
# to choose -- so an existing router keeps its host and we skip that domain. Computed per
# mode because "what else is loaded" differs: the shared file, or our sibling files.
CLAIMED=""
CLAIMED=$(TRAEFIK_MODE="$TRAEFIK_MODE" SINGLE_FILE="$SINGLE_FILE" DEST_DIR="$REAL_DEST" \
          PREFIX="$PREFIX" python3 - <<'PYCLAIM' || true
import glob, os, re
mode, prefix = os.environ["TRAEFIK_MODE"], os.environ["PREFIX"]
files = ([os.environ["SINGLE_FILE"]] if mode == "file"
         else [f for f in glob.glob(os.path.join(os.environ["DEST_DIR"], "*.yml"))
               if not os.path.basename(f).startswith(prefix)])
name_re = re.compile(r"^    ([\w.-]+):\s*$")
rule_re = re.compile(r"^\s*rule:\s*(.+?)\s*$")
for f in files:
    try: lines = open(f).read().split("\n")
    except OSError: continue
    owner = None
    for line in lines:
        m = name_re.match(line)
        if m: owner = m.group(1); continue
        m = rule_re.match(line)
        if m and owner and not owner.startswith(prefix):
            print("%s\t%s" % (m.group(1).strip('"\''), owner))
PYCLAIM
)

# rule_claimed <domain> -> echoes the owning router name if the rule is taken
rule_claimed() {
  printf '%s\n' "$CLAIMED" | awk -F'\t' -v r="Host(\`$1\`)" '$1==r {print $2; exit}'
}

mkdir -p "$DEST" 2>/dev/null || { log "cannot create $DEST"; exit 1; }

# --- 2. CF zones = the DNS whitelist (best-effort; DNS skipped if this fails) ---
ZONES=()
if [ "$MANAGE_DNS" = "1" ] && [ -n "$CF_EMAIL" ] && [ -n "$CF_KEY" ]; then
  ZRESP="$(cf GET '/zones?per_page=50&status=active')"
  if echo "$ZRESP" | jq -e '.success==true' >/dev/null 2>&1; then
    mapfile -t ZONES < <(echo "$ZRESP" | jq -r '.result[].name' | LC_ALL=C tr '[:upper:]' '[:lower:]')
    log "CF zones (whitelist): ${#ZONES[@]}"
  else
    log "CF zones fetch failed — DNS automation skipped this run"
  fi
fi

zone_for() { # echo the most specific whitelist zone that is a suffix of $1, else nothing
  local d="$1" z best=""
  for z in "${ZONES[@]}"; do
    if [ "$d" = "$z" ]; then
      [ ${#z} -gt ${#best} ] && best="$z"
      continue
    fi
    case "$d" in
      *".${z}")
        [ ${#z} -gt ${#best} ] && best="$z"
        ;;
    esac
  done
  printf '%s' "$best"
}

cf_upsert() { # cf_upsert <fqdn> <zone> <type> <content>
  local d="$1" z="$2" t="$3" c="$4" zid rid body
  zid="$(cf GET "/zones?name=$z" | jq -r '.result[0].id // empty')"
  [ -n "$zid" ] || { log "DNS: no zone id for $z"; return; }
  body="$(jq -n --arg type "$t" --arg name "$d" --arg content "$c" \
    --argjson ttl 120 --argjson proxied false \
    '{type: $type, name: $name, content: $content, ttl: $ttl, proxied: $proxied}')"
  rid="$(cf GET "/zones/$zid/dns_records?type=$t&name=$d" | jq -r '.result[0].id // empty')"
  if [ -n "$rid" ]; then
    if cf PUT "/zones/$zid/dns_records/$rid" "$body" | jq -e '.success==true' >/dev/null 2>&1; then
      log "DNS: $t $d -> $c (updated)"
    else
      log "DNS: $t update failed for $d"
    fi
  else
    if cf POST "/zones/$zid/dns_records" "$body" | jq -e '.success==true' >/dev/null 2>&1; then
      log "DNS: $t $d -> $c (created)"
    else
      log "DNS: $t create failed for $d"
    fi
  fi
}

# --- 3. per domain: DNS FIRST (so it can propagate), then the router file ---
# Traefik hot-loads a new router file the instant it appears and attempts ACME immediately; if DNS
# hasn't propagated yet that first attempt fails and Traefik backs off. So we set DNS before writing
# the file, and if any brand-NEW router file was created we force one Traefik restart at the end
# (after a short propagation wait) to trigger a clean ACME retry. Established domains never restart.
declare -A WANT=()
NEW=0
# In file mode the per-domain writes land in a scratch dir and the merge is the real
# write, so saying "written" every run would be both noisy and untrue.
if [ "$TRAEFIK_MODE" = "file" ]; then VERB="staged"; else VERB="written"; fi
NEEDS_WILDCARD=0
for d in "${DOMAINS[@]}"; do
  [ -n "$d" ] || continue
  if under_wildcard "$d"; then
    NEEDS_WILDCARD=1
    log "wildcard: $d -> *.$WILDCARD_DOMAIN (skipping per-domain Traefik/DNS)"
    continue
  fi
  if under_wildcard_instance "$d"; then
    log "wildcard instance: $d -> *.$WILDCARD_INSTANCE_DOMAIN (skipping per-domain Traefik/DNS)"
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
  # Another tool already routes this host -- it keeps it. This is checked BEFORE the write
  # so directory mode is protected too: there is no merge step there to catch the clash,
  # and two files claiming one Host() rule would just sit there generating warnings.
  # DNS is deliberately upserted above regardless of who routes the host -- the record has
  # to exist either way, the upsert is idempotent, and it is a useful backstop if the
  # other tool's DNS ever lapses.
  owner="$(rule_claimed "$d")"
  if [ -n "$owner" ]; then
    unset "WANT[$PREFIX$s.yml]"
    log "skip: $d is already routed by '$owner' — leaving that router alone"
    continue
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
  if ! cmp -s "$tmp" "$f" 2>/dev/null; then mv "$tmp" "$f"; chmod 644 "$f"; log "router: $PREFIX$s.yml $VERB ($d)"; [ "$existed" = 0 ] && NEW=1; else rm -f "$tmp"; fi
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
      rule: "HostRegexp(\`^.+\\\\.$REGEX$\`)"
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
  if ! cmp -s "$tmp" "$wf" 2>/dev/null; then mv "$tmp" "$wf"; chmod 644 "$wf"; log "router: $WILDCARD_FILE $VERB (wildcard for *.$WILDCARD_DOMAIN)"; [ "$existed" = 0 ] && NEW=1; else rm -f "$tmp"; fi
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

# --- 5b. file mode: merge the staged routers into the single dynamic file ---
# Traefik in `providers.file.filename` mode never reads $DEST, so on such a box the
# staged files above are inert. Fold them into $SINGLE_FILE instead, touching ONLY
# keys we own ("$PREFIX"*): every foreign router/service/middleware is carried through
# byte-identical (text-level splice, not a YAML round-trip, so comments and the
# formatting of config other tools own survive). hotify's own regenerate does the
# mirror-image of this, which is what lets both tools share one file.
if [ "$TRAEFIK_MODE" = "file" ]; then
  MERGE_OUT=$(STAGE="$STAGE" TARGET="$SINGLE_FILE" PREFIX="$PREFIX" python3 - <<'PYMERGE'
import glob, os, sys, tempfile

stage, target, prefix = os.environ["STAGE"], os.environ["TARGET"], os.environ["PREFIX"]
SECTIONS = ("routers", "services", "middlewares")

def split_http(text):
    """section -> {key: raw block}. Text-based on purpose: preserves foreign bytes."""
    out, section, key, buf = {}, None, None, []
    def flush():
        nonlocal key, buf
        if section and key and buf:
            out.setdefault(section, {})[key] = "\n".join(buf).rstrip() + "\n"
        key, buf = None, []
    for line in text.split("\n"):
        t = line.strip()
        indent = len(line) - len(line.lstrip(" "))
        if indent == 2 and t.endswith(":") and not t.startswith("-"):
            flush(); section = t[:-1]; continue
        if indent == 0 and t:
            flush()
            if t != "http:": section = None
            continue
        if section is None: continue
        if indent == 4 and t.endswith(":") and " " not in t:
            flush(); key = t[:-1]; buf = [line]; continue
        if key and (indent > 4 or not t):
            buf.append(line)
    flush()
    return out

def render(sections):
    parts = ["http:\n"]
    for sec in SECTIONS:
        blocks = sections.get(sec) or {}
        if not blocks: continue
        parts.append("  %s:\n" % sec)
        for name in sorted(blocks):                       # sorted => stable bytes
            parts.append(blocks[name].rstrip("\n") + "\n\n")
    return "".join(parts)

try:
    existing = open(target).read()
except FileNotFoundError:
    existing = ""
merged = split_http(existing)

# drop every key we own; the staged files are the complete truth for those
for sec in SECTIONS:
    for name in list(merged.get(sec) or {}):
        if name.startswith(prefix):
            del merged[sec][name]

# Rules already claimed by a FOREIGN router. Two routers with the same Host() rule is
# a real misconfiguration -- Traefik warns and which one wins is not something we get to
# choose -- so if another tool already routes a host, it keeps it and we skip that domain.
# This is the mirror of hotify's "owner wins": whoever is already there is the owner.
def qstrip(s):
    s = s.strip()
    if (s.startswith('"') and s.endswith('"')) or (s.startswith("'") and s.endswith("'")):
        return s[1:-1].strip()
    return s

def host_rules(sections):
    rules = {}
    for name, block in (sections.get("routers") or {}).items():
        for line in block.split("\n"):
            t = line.strip()
            if t.startswith("rule:"):
                rules.setdefault(qstrip(t[5:]), name)
                break
    return rules

claimed = host_rules(merged)   # `merged` currently holds ONLY foreign routers

skipped = []
for f in sorted(glob.glob(os.path.join(stage, prefix + "*.yml"))):
    staged = split_http(open(f).read())
    collide = None
    for rule, owner in host_rules(staged).items():
        if rule in claimed:
            collide = (rule, claimed[rule])
            break
    if collide:
        # drop this domain's service too, not just its router
        skipped.append("%s (rule already routed by %s)" % (os.path.basename(f), collide[1]))
        continue
    for sec, blocks in staged.items():
        merged.setdefault(sec, {}).update(blocks)

for m in skipped:
    sys.stderr.write("  skipped: %s\n" % m)

owned = sum(1 for sec in SECTIONS for n in (merged.get(sec) or {}) if n.startswith(prefix))
foreign = sum(1 for sec in SECTIONS for n in (merged.get(sec) or {}) if not n.startswith(prefix))
out = render(merged)

if out == existing:
    print("unchanged %d %d" % (owned, foreign)); sys.exit(0)

# atomic, same-filesystem replace so Traefik never observes a half-written file
d = os.path.dirname(target) or "."
fd, tmp = tempfile.mkstemp(dir=d, prefix=".hart-merge.")
try:
    with os.fdopen(fd, "w") as fh: fh.write(out)
    os.chmod(tmp, 0o644)
    os.replace(tmp, target)
except BaseException:
    os.path.exists(tmp) and os.unlink(tmp); raise
print("changed %d %d" % (owned, foreign))
PYMERGE
) || { log "merge into $SINGLE_FILE FAILED — left untouched"; exit 1; }

  read -r M_STATE M_OWNED M_FOREIGN <<<"$MERGE_OUT"
  log "merged into $SINGLE_FILE: $M_STATE (hart entries: $M_OWNED, foreign preserved: $M_FOREIGN)"
  # In file mode "brand new file" is meaningless (the stage starts empty every run), so
  # base the ACME restart on whether the merge actually changed the target instead —
  # otherwise every cron tick would restart Traefik.
  [ "$M_STATE" = "changed" ] && NEW=1 || NEW=0
fi

# --- 5. new domain(s) -> force one clean ACME attempt (DNS has been set + given time to propagate) ---
if [ "$NEW" = 1 ]; then
  log "new domain(s) added — waiting ${PROPAGATE_WAIT}s for DNS, then restarting Traefik for ACME"
  sleep "$PROPAGATE_WAIT"
  if sudo -n systemctl restart traefik 2>/dev/null; then
    log "traefik restarted — cert(s) will issue on the retry"
  else
    log "WARN: could not restart traefik (needs passwordless sudo) — new cert issues on the next restart"
  fi
fi

log "reconcile complete: ${#DOMAINS[@]} domain(s)"
