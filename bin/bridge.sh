#!/bin/sh
# radicle-gitea-bridge — copies the Radicle repositories that ask for CI into Gitea,
# with a real `git push`, so Gitea Actions builds them.
#
# No per-project configuration. Every pass it asks the Radicle node which
# repositories it seeds, and picks up those whose head contains $OPT_IN_PATH
# (.gitea/workflows by default): committing a workflow is the opt-in, as on GitHub.
#
# Why a push and not a Gitea pull mirror: a push always raises the push event that
# Actions matches `on: push` filters against. Mirror syncs hand Actions a bare
# branch name and filtered workflows silently never run (gitea#24824, #24926).
#
# What is copied, per repository:
#   refs/heads/*                               → refs/heads/*   canonical branches, forced
#   refs/namespaces/<delegate>/refs/tags/*     → refs/tags/*    every delegate's tags, never forced
# Radicle publishes no canonical refs/tags/ by default; a tag lives under the
# identity that pushed it. A tag two delegates disagree on is skipped and logged.
set -eu

RAD_API=${RAD_API:-http://radicle-api:8080}
GITEA_URL=${GITEA_URL:-http://gitea:3000}
GITEA_OWNER=${GITEA_OWNER:-gitea_admin}
GITEA_TOKEN_FILE=${GITEA_TOKEN_FILE:-/secrets/gitea-token}
OPT_IN_PATH=${OPT_IN_PATH:-.gitea/workflows}
INTERVAL=${INTERVAL:-30}
CACHE=${CACHE:-/cache}

log() { echo "$(date -Iseconds) $*"; }

# Read on every call: the init step may write the token after this container starts.
token() { cat "$GITEA_TOKEN_FILE" 2>/dev/null; }

# gitea METHOD PATH [curl args] → prints the HTTP status; body lands in $BODY.
BODY=$(mktemp)
gitea() {
	m=$1 p=$2; shift 2
	curl -sS -o "$BODY" -w '%{http_code}' -X "$m" -H "Authorization: token $(token)" \
		-H 'Content-Type: application/json' "$GITEA_URL/api/v1$p" "$@" || echo 000
}

# The Gitea repository a Radicle repository maps to. Created on first sight, with
# everything that overlaps Radicle switched off. An existing repository is only
# written to if the bridge made it (its description names the RID).
ensure_gitea_repo() {
	rid=$1 name=$2
	case $(gitea GET "/repos/$GITEA_OWNER/$name") in
	200)
		jq -e --arg rid "$rid" '.description | contains($rid)' "$BODY" >/dev/null && return 0
		log "$rid: $GITEA_OWNER/$name exists and is not a bridge copy, skipping"; return 1 ;;
	404) ;;
	*) log "$rid: Gitea unreachable ($(head -c 200 "$BODY"))"; return 1 ;;
	esac
	desc="Build copy of $rid. Push to Radicle, not here: written only by radicle-gitea-bridge."
	c=$(gitea POST /user/repos -d "$(jq -n --arg n "$name" --arg d "$desc" '{name:$n, private:true, description:$d}')")
	[ "$c" = 201 ] || { log "$rid: cannot create $GITEA_OWNER/$name: $c $(head -c 200 "$BODY")"; return 1; }
	# A new repository can arrive with Actions off; nothing runs until it is on.
	gitea PATCH "/repos/$GITEA_OWNER/$name" -d '{"has_actions":true,"has_packages":true,
		"has_issues":false,"has_pull_requests":false,"has_wiki":false,"has_projects":false,
		"has_releases":false}' >/dev/null
	log "$rid: created $GITEA_OWNER/$name"
}

sync_repo() {
	rid=$1
	meta=$(curl -fsS "$RAD_API/api/v1/repos/$rid") || { log "$rid: radicle-api unreachable"; return; }
	name=$(printf '%s' "$meta" | jq -r '.payloads["xyz.radicle.project"].data.name')
	head=$(printf '%s' "$meta" | jq -r '.payloads["xyz.radicle.project"].meta.head')

	# Opt-in check against the API, so repositories without CI are never fetched.
	curl -fsS -o /dev/null "$RAD_API/api/v1/repos/$rid/tree/$head/$OPT_IN_PATH" 2>/dev/null || return 0

	ensure_gitea_repo "$rid" "$name" || return 0

	export GIT_DIR="$CACHE/${rid#rad:}.git"
	[ -d "$GIT_DIR" ] || git init -q --bare "$GIT_DIR"

	# Each delegate's tags land in a private namespace first; they only become
	# refs/tags/* below, once every delegate that has a tag agrees on it.
	set -- "+refs/heads/*:refs/heads/*"
	for did in $(printf '%s' "$meta" | jq -r '.delegates[].id'); do
		nid=${did#did:key:}
		set -- "$@" "+refs/namespaces/$nid/refs/tags/*:refs/rad-tags/$nid/*"
	done
	if ! out=$(git fetch --quiet --prune "$RAD_API/$rid.git" "$@" 2>&1); then
		log "$rid: fetch failed:"; echo "$out"; return
	fi
	git for-each-ref --format='%(objectname) %(refname)' refs/rad-tags/ |
		awk '{ sub("^refs/rad-tags/[^/]+/", "", $2)
		       if (($2 in t) && t[$2] != $1) bad[$2] = 1; t[$2] = $1 }
		     END { for (k in t) print ((k in bad) ? "CONFLICT" : t[k]), k }' |
		while read -r obj tag; do
			if [ "$obj" = CONFLICT ]; then log "$rid: delegates disagree on tag $tag, skipping"
			else git update-ref "refs/tags/$tag" "$obj"; fi
		done

	# Sent as a header so the token never appears in a URL, `ps` or the logs.
	auth="Authorization: Basic $(printf '%s:%s' "$GITEA_OWNER" "$(token)" | base64 | tr -d '\n')"
	# Branches are forced (Radicle's canonical head is the truth). Tags are not: a
	# tag moved after it was built must fail loudly here, not silently rebuild a
	# different image under the same version.
	if out=$(git -c http.extraHeader="$auth" push "$GITEA_URL/$GITEA_OWNER/$name.git" \
		"+refs/heads/*:refs/heads/*" "refs/tags/*:refs/tags/*" 2>&1); then
		case $out in *"Everything up-to-date"*) ;; *) log "$rid → $GITEA_OWNER/$name:"; echo "$out" ;; esac
	else
		log "$rid → $GITEA_OWNER/$name: push failed:"; echo "$out"
	fi
	unset GIT_DIR
}

log "bridging $RAD_API → $GITEA_URL/$GITEA_OWNER, opt-in: $OPT_IN_PATH, every ${INTERVAL}s"
while :; do
	if [ -z "$(token)" ]; then
		log "waiting for the Gitea token at $GITEA_TOKEN_FILE"
	elif rids=$(curl -fsS "$RAD_API/api/v1/repos?show=all&perPage=1000" | jq -r '.[].rid'); then
		for rid in $rids; do sync_repo "$rid"; done
	else
		log "radicle-api unreachable"
	fi
	[ -n "${ONESHOT:-}" ] && exit 0
	sleep "$INTERVAL"
done
