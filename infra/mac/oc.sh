# Source this to get the `oc` helper:
#   source ~/Projects/Opencode-Pocket/infra/mac/oc.sh
# Then `oc` runs opencode against the fixed Opencode-Pocket server.
oc() {
  local url="${OPENCODE_POCKET_URL:-http://127.0.0.1:4096}"
  command opencode --server "$url" "$@"
}
