#!/usr/bin/env bash
# Step 4 - create the local kind cluster (skipped for remote installs): host directories from the vendor's
# kind config, the GCP key file the node mounts, `kind create cluster`, and the dedicated kubeconfig.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config
require_specs
if [[ $S2_REMOTE_INSTALLATION == Y ]]; then info "remote installation: nothing to do here"; next "./05-prepare-cluster.sh"; exit 0; fi
require_cmd kind kubectl docker spruce yq jq
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT

log "Step 4: kind cluster"
docker info >/dev/null 2>&1 || die "cannot talk to Docker from this shell: log out and back in (docker group), or start the docker service"

kindcfg="$KUSTOMIZE_DIR/kind-setup/kindconfig.yaml"
patch="$ENV_DIR/kind/patch.yaml"
[[ -f $kindcfg ]] || die "kind config not found: $kindcfg"
merged="$TMPD/kindconfig.yaml"
if [[ -f $patch ]]; then spruce merge "$kindcfg" "$patch" > "$merged"; else spruce merge "$kindcfg" > "$merged"; fi

# cluster name: the vendor config wins, otherwise the configured name
name=$(yq -r '.name // ""' "$merged"); name=${name:-$S2_KIND_CLUSTER_NAME}
if [[ $name != "$S2_KIND_CLUSTER_NAME" || $S2_KUBE_CONTEXT != "kind-$name" ]]; then
  S2_KIND_CLUSTER_NAME=$name; S2_KUBE_CONTEXT="kind-$name"; save_config
  info "cluster name from kind config is '$name'; config updated (context $S2_KUBE_CONTEXT)"
fi

mount_host_path() {   # mount_host_path CONTAINER_PATH -> hostPath from the merged kind config
  local p
  p=$(yq -r ".nodes[]?.extraMounts[]? | select(.containerPath == \"$1\") | .hostPath" "$merged" 2>/dev/null | head -n1)
  [[ -n $p && $p != null ]] || p=$(grep -A1 -F "$1" "$merged" | grep hostPath | awk '{ print $2 }' | head -n1 || true)
  printf '%s' "$p"
}
log_path=${S2_LOG_PATH:-$(mount_host_path /var/log/s2)}
stores_path=${S2_STORES_PATH:-$(mount_host_path /var/selector/storage)}
[[ -n $log_path && -n $stores_path ]] || die "cannot find the hostPath for /var/log/s2 or /var/selector/storage in the kind config; set s2_log_path / s2_stores_path in $S2CTL_CONFIG"
info "log path: $log_path"
info "stores path: $stores_path"

log "Step 4: host directories"
[[ -d $log_path ]] || "${SUDO[@]}" mkdir -p "$log_path"
while IFS= read -r store; do
  [[ -n $store ]] || continue
  [[ -d $stores_path/$store ]] || "${SUDO[@]}" mkdir -p "$stores_path/$store"
  if [[ $store =~ (loki|obmp|prometheus/data|elasticsearch-data|gitea-shared-storage|chroma-data|openbao-data) ]]; then
    "${SUDO[@]}" chmod "$S2_STORE_MODE" "$stores_path/$store"     # vendor default 777; see README before tightening
    info "$store (mode $S2_STORE_MODE)"
  else
    info "$store"
  fi
done < <(jq -r '.stores[]' "$KUSTOMIZE_DIR/kind-setup/kindsetup.json")

# the vendor's kind config bind-mounts $S2CTL_DIR/gcp.json; Docker would create a directory if the file is missing
key_mount="$S2CTL_DIR/gcp.json"
if [[ -d $key_mount ]]; then "${SUDO[@]}" rm -rf "$key_mount"; warn "removed a directory Docker had created at $key_mount"; fi
[[ -f $key_mount ]] || install -m 0600 "$S2_GCP_KEY" "$key_mount"

log "Step 4: create cluster '$name'"
umask 077
if kind get clusters 2>/dev/null | grep -qx "$name"; then
  info "kind cluster '$name' already exists; exporting its kubeconfig"
  kind export kubeconfig --name "$name" --kubeconfig "$KUBECONFIG"
else
  kind create cluster --name "$name" --kubeconfig "$KUBECONFIG" --config "$merged"
fi
chmod 0600 "$KUBECONFIG"
kubectl config use-context "$S2_KUBE_CONTEXT" >/dev/null

for i in $(seq 1 60); do
  kubectl get serviceaccount default >/dev/null 2>&1 && break
  (( i == 60 )) && die "the default service account never appeared; check: docker ps, kubectl get nodes"
  info "waiting for the cluster to become ready ($i/60)"; sleep 5
done
assert_context
kubectl get nodes
next "./05-prepare-cluster.sh"
