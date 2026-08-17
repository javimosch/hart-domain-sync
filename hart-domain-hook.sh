#!/usr/bin/env bash
# hart-domain-hook — the HART_DOMAIN_HOOK target. hart calls this synchronously in its request
# path as `hart-domain-hook.sh <add|remove> <domain> <owner> <artifact>`.
# Dispatch remove events to the fast `--remove` path and everything else to a full reconcile.
# All work runs in the background so the `hart domain` HTTP response returns immediately.

trim() { printf '%s' "$1" | LC_ALL=C tr -d '\r' | LC_ALL=C sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

SYNC="$(trim "${HART_DOMAIN_SYNC:-/opt/hart/hart-domain-sync.sh}")"
[ -n "$SYNC" ] || SYNC="/opt/hart/hart-domain-sync.sh"
LOG="$(trim "${HART_DOMAIN_SYNC_LOG:-/opt/hart/domain-sync.log}")"
[ -n "$LOG" ] || LOG="/opt/hart/domain-sync.log"
# A trailing slash on a configured file path would make the path a directory and
# break the "is this script executable" check or the log append. Strip them all
# except a bare root, which would never be a valid script/log path.
while [[ "$SYNC" == */ && "$SYNC" != "/" ]]; do SYNC="${SYNC%/}"; done
while [[ "$LOG" == */ && "$LOG" != "/" ]]; do LOG="${LOG%/}"; done
LOG_DIR="$(dirname "$LOG")"
if ! mkdir -p "$LOG_DIR" 2>/dev/null || [ ! -w "$LOG_DIR" ]; then
  LOG="/tmp/hart-domain-sync.log"
fi
# A configured log path that points to a directory would fail the append below.
[ -d "$LOG" ] && LOG="/tmp/hart-domain-sync.log"

# Detach from hart's request stdout/stderr once the log path is final.
exec >/dev/null 2>&1

if [ -d "$SYNC" ] || [ ! -x "$SYNC" ]; then
  printf '%s\n' "HART_DOMAIN_SYNC is not an executable file: $SYNC" >>"$LOG"
  exit 1
fi
EVENT="$(trim "${1:-}" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
case "$EVENT" in
  remove)
    DOMAIN="$(trim "${2:-}")"
    if [ -z "$DOMAIN" ]; then
      printf '%s\n' "hart-domain-hook: missing domain for remove" >>"$LOG"
      exit 1
    fi
    nohup "$SYNC" --remove "$DOMAIN" >>"$LOG" 2>&1 &
    ;;
  *)      nohup "$SYNC" >>"$LOG" 2>&1 & ;;
esac
exit 0
