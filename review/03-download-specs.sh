#!/usr/bin/env bash
# Step 3 - authenticate with the service account, download the deployment specs tarball from the vendor's
# GCS bucket, extract it, and apply the S2_INSTANCE / S2_NAME / FQDN overrides to config.properties.
# config.properties is edited as a KEY=VALUE file (never sourced, no sed injection).
# Set S2_SKIP_SPECS_UPDATE=Y to keep specs that are already on disk.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
load_config
require_cmd jq tar sha256sum

log "Step 3: deployment specs -> $KUSTOMIZE_DIR"
[[ -s $S2_GCP_KEY ]] || die "GCP key not found: $S2_GCP_KEY"

if [[ ! -d $S2_DEPLOY_DIR ]]; then
  "${SUDO[@]}" install -d -m 0755 "$S2_DEPLOY_DIR"
  "${SUDO[@]}" chown "$(id -u):$(id -g)" "$S2_DEPLOY_DIR"
fi
mkdir -p "$S2_DEPLOY_DIR/backups"

download=Y
if [[ -d $ENV_DIR ]]; then
  if [[ ${S2_SKIP_SPECS_UPDATE:-N} == Y ]]; then
    download=N; info "S2_SKIP_SPECS_UPDATE=Y: keeping the specs already on disk"
  elif confirm "Specs for '$S2_DEPLOYMENT_NAME' already exist. Download again from the bucket (the current copy is backed up)?"; then
    download=Y
  else
    download=N
  fi
fi

if [[ $download == Y ]]; then
  require_cmd gcloud
  cfg=$(gcloud_configuration)
  bucket=$(bucket_name "$S2_DEPLOYMENT_NAME")
  info "service account: $(jq -r .client_email "$S2_GCP_KEY")"
  info "bucket: gs://$bucket"
  if [[ -d $KUSTOMIZE_DIR ]]; then
    backup="$S2_DEPLOY_DIR/backups/$(date +%Y%m%d-%H%M%S)-kustomize"
    mv "$KUSTOMIZE_DIR" "$backup"; info "previous specs moved to $backup"
  fi
  mkdir -p "$KUSTOMIZE_DIR"
  gcloud storage --configuration "$cfg" cp "gs://$bucket/$S2_DEPLOYMENT_NAME.tgz" "$KUSTOMIZE_DIR/"
  tar -xzf "$KUSTOMIZE_DIR/$S2_DEPLOYMENT_NAME.tgz" -C "$KUSTOMIZE_DIR"
  info "extracted $(find "$KUSTOMIZE_DIR" -type f | wc -l) files"
  vendor_script="$ENV_DIR/s2kustomize/scripts/s2ctl.sh"
  if [[ -f $vendor_script ]]; then
    info "vendor s2ctl.sh in this tarball: sha256 $(sha256_of "$vendor_script") (use it for upgrade/teleport/uninstall)"
  fi
fi

require_specs

log "Step 3: config.properties overrides"
info "S2_VERSION=$(get_kv "$PROPS_FILE" S2_VERSION || echo '?')"
apply_prop() {   # apply_prop KEY VALUE
  if set_kv "$PROPS_FILE" "$1" "$2"; then info "$1=$2"; else warn "$1 is not present in config.properties; left unset"; fi
}
if [[ -n $S2_INSTANCE ]]; then
  apply_prop S2_INSTANCE "$S2_INSTANCE"
else
  info "S2_INSTANCE=$(get_kv "$PROPS_FILE" S2_INSTANCE || echo '?') (vendor value)"
fi
if [[ -n $S2_FQDN ]]; then
  apply_prop S2_INGRESS_DOMAIN_MAIN     "$S2_FQDN"
  apply_prop S2_INGRESS_DOMAIN_MON      "${S2_FQDN/./-mon.}"
  apply_prop S2_INGRESS_DOMAIN_ENGINE   "${S2_FQDN/./-engine.}"
  apply_prop S2_INGRESS_DOMAIN_REGISTRY "${S2_FQDN/./-registry.}"
  apply_prop S2_NAME "${S2_NAME:-https://$S2_FQDN}"
elif [[ -n $S2_NAME ]]; then
  apply_prop S2_NAME "$S2_NAME"
else
  info "S2_NAME=$(get_kv "$PROPS_FILE" S2_NAME || echo '?') (vendor value)"
fi

log "Step 3: apps found in $ENV_DIR"
list_apps | sed 's/^/    /'
if [[ $S2_REMOTE_INSTALLATION == N ]]; then next "./04-create-kind-cluster.sh"; else next "./05-prepare-cluster.sh (remote install: step 4 is skipped)"; fi
