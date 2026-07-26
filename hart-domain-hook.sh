#!/usr/bin/env bash
# hart-domain-hook — the HART_DOMAIN_HOOK target. hart calls this synchronously in its request
# path as `hart-domain-hook.sh <add|remove> <domain> <owner> <artifact>`; we fire the full
# reconcile in the background and return immediately so the `hart domain` HTTP response isn't
# blocked on Cloudflare/Traefik I/O. The reconcile is idempotent and prunes removed mappings, so
# ignoring the args is fine — it will re-fetch the current desired set from hart.
exec >/dev/null 2>&1
nohup /opt/hart/hart-domain-sync.sh >>/opt/hart/domain-sync.log 2>&1 &
exit 0
