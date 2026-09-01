#!/usr/bin/env bash
# Step 8 (optional) - what `s2ctl.sh gets2mspecs` does: copy the s2ctl binary and get_reports.py out of the
# running deployment into $S2_BIN_DIR, and the s2ml/services specs into $S2_DEPLOY_DIR/config (git-initialised).
# The helper pod is always deleted, even when a copy fails.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config
require_cmd kubectl git

config_dir="$S2_DEPLOY_DIR/config"
pod=s2ml-extractor
TMPD=$(mktemp -d)
cleanup() { rm -rf "$TMPD"; kubectl -n s2 delete pod "$pod" --ignore-not-found=true >/dev/null 2>&1 || true; }
trap cleanup EXIT

log "Step 8: extract tools from the running deployment"
assert_context
image=$(kubectl -n s2 get statefulset s2-explorer -o jsonpath='{.spec.template.spec.initContainers[0].image}')
[[ -n $image ]] || die "cannot determine the deploy image from statefulset/s2-explorer (is s2ap running?)"
repo_pod=$(kubectl -n s2 get pods -l app=s2-repo -o jsonpath='{.items[0].metadata.name}')
[[ -n $repo_pod ]] || die "no s2-repo pod found in namespace s2"

kubectl -n s2 delete pod "$pod" --ignore-not-found=true >/dev/null
kubectl -n s2 apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $pod
spec:
  restartPolicy: Never
  containers:
  - name: runner
    image: $image
    args: ["sleep", "86400"]
EOF
kubectl -n s2 wait --for=condition=Ready "pod/$pod" --timeout=600s

kubectl cp "s2/$repo_pod:/usr/share/nginx/html/bin/linux/s2ctl" "$TMPD/s2ctl"
"${SUDO[@]}" install -o root -g root -m 0755 "$TMPD/s2ctl" "$S2_BIN_DIR/s2ctl"
info "installed $S2_BIN_DIR/s2ctl ($(sha256_of "$TMPD/s2ctl"))"

if [[ -d $config_dir ]]; then
  mkdir -p "$S2_DEPLOY_DIR/backups"
  backup="$S2_DEPLOY_DIR/backups/$(date +%Y%m%d-%H%M%S)-config"
  mv "$config_dir" "$backup"; info "previous config moved to $backup"
fi
mkdir -p "$config_dir/base" "$config_dir/$S2_DEPLOYMENT_NAME"
kubectl cp "s2/$pod:/deploy/scripts/get_reports.py" "$config_dir/get_reports.py"
"${SUDO[@]}" install -o root -g root -m 0755 "$config_dir/get_reports.py" "$S2_BIN_DIR/get_reports.py"
kubectl cp "s2/$pod:/deploy/base/services"      "$config_dir/base/services"
kubectl cp "s2/$pod:/deploy/base/s2ml-common"   "$config_dir/base/s2ml-common"
kubectl cp "s2/$pod:/deploy/$S2_DEPLOYMENT_NAME/services" "$config_dir/$S2_DEPLOYMENT_NAME/services"
kubectl cp "s2/$pod:/deploy/$S2_DEPLOYMENT_NAME/s2ml"     "$config_dir/$S2_DEPLOYMENT_NAME/s2ml"
( cd "$config_dir" && git init -q . && git add . && git -c user.name=s2-install -c user.email=s2-install@localhost commit -q -m "First commit" )

log "Step 8: done -> $config_dir"
info "from here on use the vendor script for day-2 work: s2ctl.sh applyConfig | upgrade | refreshIngress | teleport"
