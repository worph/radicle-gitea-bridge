# radicle-gitea-bridge — git, curl and jq on Alpine, plus two shell scripts.
FROM alpine/git:v2.47.2
RUN apk add --no-cache curl jq
COPY bin/bridge.sh /usr/local/bin/bridge
COPY bin/bridge-init.sh /usr/local/bin/bridge-init
# Applied here rather than trusted from the checkout: a Windows-hosted checkout
# records every file 100644.
RUN chmod 0755 /usr/local/bin/bridge /usr/local/bin/bridge-init
# alpine/git's entrypoint is `git`; this image runs its own commands.
ENTRYPOINT []
CMD ["bridge"]
