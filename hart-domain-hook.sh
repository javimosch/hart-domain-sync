#!/usr/bin/env bash
# hart-domain-hook — the HART_DOMAIN_HOOK target. hart calls this synchronously in its request
# path as `hart-domain-hook.sh <add|remove> <domain> <owner> <artifact>`.
# Dispatch remove events to the fast `--remove` path and everything else to a full reconcile.
# All work runs in the background so the `hart domain` HTTP response returns immediately.
exec >/dev/null 2>&1
SYNC="${HART_DOMAIN_SYNC:-/opt/hart/hart-domain-sync.sh}"
LOG="${HART_DOMAIN_SYNC_LOG:-/opt/hart/domain-sync.log}"
case "${1:-}" in
  remove) nohup "$SYNC" --remove "${2:-}" >>"$LOG" 2>&1 & ;;
  *)      nohup "$SYNC" >>"$LOG" 2>&1 & ;;
esac
exit 0
