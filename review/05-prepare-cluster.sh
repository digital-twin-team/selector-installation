#!/usr/bin/env bash
# Step 5 - verify the target cluster is the one you mean, then create the namespaces, the GPG key secret
# (s2 and s2-system), the registry pull secret in every app namespace, and optionally a custom CoreDNS config.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config
require_specs
require_cmd kubectl yq jq

log "Step 5: target cluster"
assert_context
ctx=$(current_context)

if kubectl get namespace s2 >/dev/null 2>&1 && kubectl -n s2 get configmap s2-config >/dev/null 2>&1; then
  remote_name=$(kubectl -n s2 get configmap s2-config -o jsonpath='{.data.S2_NAME}')
  remote_setup=$(kubectl -n s2 get configmap s2-config -o jsonpath='{.data.S2_SETUP}')
  local_name=$(get_kv "$PROPS_FILE" S2_NAME || true)
  local_setup=$(get_kv "$PROPS_FILE" S2_SETUP || true)
  if [[ $remote_name != "$local_name" || $remote_setup != "$local_setup" ]]; then
    warn "cluster already runs S2_NAME='$remote_name' S2_SETUP='$remote_setup'; local specs say S2_NAME='$local_name' S2_SETUP='$local_setup'"
    warn "installing these specs may break the deployment that is already on '$ctx'"
    confirm_typed "Continue anyway?" "$ctx" || die "aborted"
  else
    info "cluster already has an s2 deployment matching these specs (re-install/refresh)"
  fi
elif [[ $S2_REMOTE_INSTALLATION == Y ]]; then
  confirm_typed "Fresh install onto the remote cluster above" "$ctx" || die "aborted"
fi

log "Step 5: namespaces and secrets"
while IFS= read -r app; do
  ns=$(app_namespace "$app")
  if [[ -z $ns ]]; then warn "$app/kustomization.yaml has no namespace; skipping"; continue; fi
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  if [[ $ns == s2 || $ns == s2-system ]]; then
    ns="$ns" yq '.metadata.namespace = strenv(ns)' "$S2_GPG_KEY" | kubectl apply -f - >/dev/null
    info "$ns: namespace, GPG key secret"
  else
    info "$ns: namespace"
  fi
  ensure_pull_secret "$ns"
done < <(list_apps)

if [[ ${S2_SET_DEFAULT_NS:-Y} == Y ]]; then
  kubectl config set-context --current --namespace=s2 >/dev/null
  info "default namespace of context $ctx set to s2"
fi

if [[ -n $S2_COREDNS_CONFIG ]]; then
  log "Step 5: CoreDNS config from $S2_COREDNS_CONFIG"
  [[ -f $S2_COREDNS_CONFIG ]] || die "CoreDNS config not found: $S2_COREDNS_CONFIG"
  kubectl -n kube-system create configmap coredns --from-file=Corefile="$S2_COREDNS_CONFIG" --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n kube-system rollout restart deployment coredns
  kubectl -n kube-system rollout status deployment coredns --timeout=120s
fi

next "./06-deploy-apps.sh"
