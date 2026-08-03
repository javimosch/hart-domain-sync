#!/usr/bin/env bash
# hart-domain-hook — the HART_DOMAIN_HOOK target. hart calls this synchronously in its request
# path as `hart-domain-hook.sh <add|set|remove> <domain> <owner> <artifact>`. We return
# immediately so the `hart domain` HTTP response isn't blocked on Cloudflare/Traefik I/O.
#   add/set  → full background reconcile (idempotent, also prunes stale mappings).
#   remove   → fast background removal of the single per-domain router; the timer is the safety net.
exec >/dev/null 2>&1
EVENT="${1:-}"; DOMAIN="${2:-}"
if [ "$EVENT" = "remove" ] && [ -n "$DOMAIN" ]; then
  nohup /opt/hart/hart-domain-sync.sh --remove "$DOMAIN" >>/opt/hart/domain-sync.log 2>&1 &
else
  nohup /opt/hart/hart-domain-sync.sh >>/opt/hart/domain-sync.log 2>&1 &
fi
exit 0
