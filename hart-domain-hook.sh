#!/usr/bin/env bash
# hart-domain-hook — the HART_DOMAIN_HOOK target. hart calls this synchronously in its request
# path as `hart-domain-hook.sh <add|remove> <domain> <owner> <artifact>`. `add`/`set` fire a
# full reconcile in the background; `remove` runs the fast --remove path so the router is cleaned
# up immediately. Everything is backgrounded so the `hart domain` HTTP response is not blocked.
exec >/dev/null 2>&1
EVENT="${1:-}"
DOMAIN="${2:-}"
case "$EVENT" in
  remove)
    nohup /opt/hart/hart-domain-sync.sh --remove "$DOMAIN" >>/opt/hart/domain-sync.log 2>&1 &
    ;;
  *)
    nohup /opt/hart/hart-domain-sync.sh >>/opt/hart/domain-sync.log 2>&1 &
    ;;
esac
exit 0
