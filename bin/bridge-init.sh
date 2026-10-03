#!/bin/sh
# bridge-init — mints the bridge's Gitea credentials, once.
#
# Signs in as the Gitea admin with the server's default app password (the same
# one the Gitea app's own create-admin step sets), because token management only
# accepts a password. Leaves behind:
#   $SECRETS_DIR/gitea-token  a token for the bridge: write:repository (push) and
#                             write:user (create the repositories it copies into)
#   REGISTRY_TOKEN            a user-level Actions secret with write:package, so every
#                             repository the bridge creates can push images without
#                             per-repository setup. The token Actions injects as
#                             secrets.GITHUB_TOKEN is refused by Gitea's registry.
# Safe to re-run: both tokens are replaced.
set -eu
GITEA_URL=${GITEA_URL:-http://gitea:3000}
GITEA_OWNER=${GITEA_OWNER:-gitea_admin}
SECRETS_DIR=${SECRETS_DIR:-/secrets}
: "${GITEA_PASSWORD:?the Gitea admin password}"
A=$GITEA_URL/api/v1

# The password goes to curl on stdin, never on its command line.
admin() { printf 'user = "%s:%s"\n' "$GITEA_OWNER" "$GITEA_PASSWORD" | curl -sS -K - -H 'Content-Type: application/json' "$@"; }

# Gitea may still be migrating, and its admin account may not exist yet. Bounded:
# an init step that blocks forever would hold the install open forever.
i=0
until admin -f -o /dev/null "$A/user" 2>/dev/null; do
	i=$((i + 1)); [ $i -lt 80 ] || { echo "Gitea not ready after 240s" >&2; exit 1; }
	sleep 3
done

mint() { # name scopes-json → token
	admin -o /dev/null -X DELETE "$A/users/$GITEA_OWNER/tokens/$1"
	admin -f -X POST "$A/users/$GITEA_OWNER/tokens" -d "{\"name\":\"$1\",\"scopes\":$2}" | jq -er .sha1
}
bridge=$(mint radicle-gitea-bridge '["write:repository","write:user"]')
registry=$(mint actions-registry-push '["write:package"]')

admin -f -o /dev/null -X PUT "$A/user/actions/secrets/REGISTRY_TOKEN" -d "$(jq -n --arg d "$registry" '{data:$d}')"

umask 077
printf '%s' "$bridge" > "$SECRETS_DIR/gitea-token.new"
mv "$SECRETS_DIR/gitea-token.new" "$SECRETS_DIR/gitea-token"
echo "bridge token and REGISTRY_TOKEN secret are in place"
