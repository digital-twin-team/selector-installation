#!/usr/bin/env bash
# Step 2 - collect the deployment configuration and write ~/.s2ctl/config (mode 0600).
# Precedence: environment variable (S2_GCP_KEY, S2_GPG_KEY, S2_DEPLOY_DIR, S2_FQDN, ...) > existing config > prompt.
# Set S2_NONINTERACTIVE=Y to accept every default/environment value without prompting.
# The file uses the vendor's keys, so `s2ctl.sh upgrade` / `applyConfig` keep working after this installer.
for _lib in "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh" "$(dirname "${BASH_SOURCE[0]}")/common.sh"; do
  # shellcheck source=lib/common.sh
  [[ -f $_lib ]] && { source "$_lib"; break; }
done
[[ $(type -t die 2>/dev/null) == function ]] || { echo "ERROR: common.sh not found (expected in lib/ next to this script, or next to it)" >&2; exit 1; }
require_cmd jq yq kubectl
umask 077
install -d -m 0700 "$S2CTL_DIR"
load_config --optional

log "Step 2: configuration ($S2CTL_CONFIG)"

ask S2_GCP_KEY   "Path to the GCP service-account JSON key"      "${S2_GCP_KEY:-$S2CTL_DIR/gcp.json}"
ask S2_GPG_KEY   "Path to the GPG private-key manifest (yaml)"    "${S2_GPG_KEY:-$S2CTL_DIR/gpg.yaml}"
ask S2_DEPLOY_DIR "Directory for the deployment specs"           "${S2_DEPLOY_DIR:-/opt/s2/deployments}"
ask S2_BIN_DIR   "Directory for installed tools"                  "${S2_BIN_DIR:-/usr/local/bin}"
S2_GCP_KEY=${S2_GCP_KEY/#\~/$HOME}; S2_GPG_KEY=${S2_GPG_KEY/#\~/$HOME}; S2_DEPLOY_DIR=${S2_DEPLOY_DIR/#\~/$HOME}

[[ -s $S2_GCP_KEY ]] || die "GCP key not found: $S2_GCP_KEY"
email=$(jq -er '.client_email' "$S2_GCP_KEY" 2>/dev/null) || die "$S2_GCP_KEY is not a service-account key (no client_email)"
[[ -s $S2_GPG_KEY ]] || die "GPG manifest not found: $S2_GPG_KEY"
yq -e '.kind' "$S2_GPG_KEY" >/dev/null 2>&1 || die "$S2_GPG_KEY does not look like a Kubernetes manifest"
chmod 0600 "$S2_GCP_KEY" "$S2_GPG_KEY" 2>/dev/null || warn "could not chmod 0600 the key files (not owned by you?)"

default_name=${email#customer-sa-}; default_name=${default_name%@s2-infra.iam.gserviceaccount.com}
ask S2_DEPLOYMENT_NAME "Deployment name (derived from the key's service account)" "${S2_DEPLOYMENT_NAME:-$default_name}"

ask S2_REMOTE_INSTALLATION "Install onto an existing remote cluster instead of a local kind cluster? (Y/N)" "${S2_REMOTE_INSTALLATION:-N}"
S2_REMOTE_INSTALLATION=${S2_REMOTE_INSTALLATION^^}
[[ $S2_REMOTE_INSTALLATION == Y || $S2_REMOTE_INSTALLATION == N ]] || die "answer Y or N"

if [[ $S2_REMOTE_INSTALLATION == N ]]; then
  ask S2_KIND_CLUSTER_NAME "kind cluster name" "${S2_KIND_CLUSTER_NAME:-kind}"
  S2_KUBE_CONTEXT="kind-$S2_KIND_CLUSTER_NAME"
  ask S2_STORE_MODE "Mode for the vendor's world-writable host stores (777 is the vendor default; see README)" "${S2_STORE_MODE:-777}"
  [[ $S2_STORE_MODE =~ ^[0-7]{3,4}$ ]] || die "store mode must be octal, e.g. 777 or 770"
  # The vendor's kind config bind-mounts this exact path into the node; make sure it is a regular 0600 file.
  if [[ $(readlink -f "$S2_GCP_KEY") != "$(readlink -f "$S2CTL_DIR/gcp.json")" ]]; then
    install -m 0600 "$S2_GCP_KEY" "$S2CTL_DIR/gcp.json"
    info "copied the GCP key to $S2CTL_DIR/gcp.json (mounted into the kind node)"
  fi
else
  ask S2_KUBE_CONTEXT "kube context of the target cluster" "${S2_KUBE_CONTEXT:-}"
  [[ -n $S2_KUBE_CONTEXT ]] || die "a kube context is required for remote installs"
  if ! kubectl config get-contexts -o name 2>/dev/null | grep -qx "$S2_KUBE_CONTEXT"; then
    src="$HOME/.kube/config"
    if [[ -f $src ]] && kubectl --kubeconfig "$src" config get-contexts -o name 2>/dev/null | grep -qx "$S2_KUBE_CONTEXT"; then
      info "copying context '$S2_KUBE_CONTEXT' from $src into $KUBECONFIG (flattened, 0600)"
      kubectl --kubeconfig "$src" config view --minify --flatten --context "$S2_KUBE_CONTEXT" > "$KUBECONFIG"
      kubectl config use-context "$S2_KUBE_CONTEXT" >/dev/null
    else
      die "context '$S2_KUBE_CONTEXT' is in neither $KUBECONFIG nor $src; place a kubeconfig containing it at $KUBECONFIG"
    fi
  fi
fi

ask S2_FQDN     "Public FQDN for this deployment (blank keeps the vendor specs' value)"        "${S2_FQDN:-}"
ask S2_NAME     "Override S2_NAME (blank = https://<fqdn>, or the vendor value if no FQDN)"      "${S2_NAME:-}"
ask S2_INSTANCE "Override S2_INSTANCE (blank keeps the vendor value)"                           "${S2_INSTANCE:-}"

save_config
log "Step 2: saved $S2CTL_CONFIG"
sed 's/^/    /' "$S2CTL_CONFIG"
info "(to blank a value later, edit the file directly)"
if [[ -n $S2_FQDN ]]; then
  info "DNS records needed -> this VM: $S2_FQDN, ${S2_FQDN/./-mon.}, ${S2_FQDN/./-engine.}, ${S2_FQDN/./-registry.}"
fi
next "./03-download-specs.sh"
