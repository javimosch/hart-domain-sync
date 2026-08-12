#!/usr/bin/env bash
# hart-domain-hook — the HART_DOMAIN_HOOK target. hart calls this synchronously in its request
# path as `hart-domain-hook.sh <add|remove> <domain> <owner> <artifact>`.
# Dispatch remove events to the fast `--remove` path and everything else to a full reconcile.
# All work runs in the background so the `hart domain` HTTP response returns immediately.
exec >/dev/null 2>&1
SYNC="${HART_DOMAIN_SYNC:-/opt/hart/hart-domain-sync.sh}"
LOG="${HART_DOMAIN_SYNC_LOG:-/opt/hart/domain-sync.log}"
LOG_DIR="$(dirname "$LOG")"
if ! mkdir -p "$LOG_DIR" 2>/dev/null || [ ! -w "$LOG_DIR" ]; then
  LOG="/tmp/hart-domain-sync.log"
fi
[ -x "$SYNC" ] || { printf '%s\n' "HART_DOMAIN_SYNC not found or not executable: $SYNC" >>"$LOG"; exit 1; }
case "${1:-}" in
  remove) nohup "$SYNC" --remove "${2:-}" >>"$LOG" 2>&1 & ;;
  *)      nohup "$SYNC" >>"$LOG" 2>&1 & ;;
esac
exit 0
