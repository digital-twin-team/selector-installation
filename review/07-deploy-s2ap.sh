#!/usr/bin/env bash
# Step 7 - apply the s2ap application specs into the s2 namespace and wait for the pods.
# Usage: 07-deploy-s2ap.sh [--wait MINUTES]   (default 30; 0 = apply and return immediately)
for _lib in "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh" "$(dirname "${BASH_SOURCE[0]}")/common.sh"; do
  # shellcheck source=lib/common.sh
  [[ -f $_lib ]] && { source "$_lib"; break; }
done
[[ $(type -t die 2>/dev/null) == function ]] || { echo "ERROR: common.sh not found (expected in lib/ next to this script, or next to it)" >&2; exit 1; }
load_config
require_specs
require_cmd kubectl kustomize helm yq jq
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT

WAIT_MIN=30
while [[ $# -gt 0 ]]; do
  case $1 in
    --wait) WAIT_MIN=$2; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ $WAIT_MIN =~ ^[0-9]+$ ]] || die "--wait takes a number of minutes"

dir="$ENV_DIR/s2ap"
[[ -d $dir ]] || die "s2ap specs not found at $dir"

log "Step 7: s2ap -> namespace s2"
assert_context
info "S2_VERSION=$(get_kv "$PROPS_FILE" S2_VERSION || echo '?')  S2_NAME=$(get_kv "$PROPS_FILE" S2_NAME || echo '?')"
confirm "Apply s2ap to $(current_context)?" || die "aborted"

ensure_pull_secret s2
kctl -n s2 delete jobs --all >/dev/null      # vendor behaviour: jobs re-run on every deploy
rendered="$TMPD/s2ap.yaml"
kbuild "$dir" > "$rendered"
info "rendered $(grep -c '^kind:' "$rendered") objects"
kubectl apply -f "$rendered"

if (( WAIT_MIN > 0 )); then
  log "Step 7: waiting up to $WAIT_MIN min for namespace s2"
  if wait_ns_ready s2 $(( WAIT_MIN * 60 )); then
    log "s2ap is up"
  else
    warn "s2 still has pods not ready after $WAIT_MIN min. Everything is applied; inspect with:"
    warn "  kubectl get pods -n s2 | grep -v -E 'Running|Completed'"
    exit 1
  fi
fi

info "watch progress:  watch -n 10 \"kubectl get --show-kind pods,deploy,sts -n s2 | grep -v -e '0/0' -e '1/1' -e '2/2' -e '3/3'\""
next "./08-fetch-s2ctl-tools.sh (optional: pulls the s2ctl binary and s2ml specs used by 's2ctl.sh applyConfig')"
