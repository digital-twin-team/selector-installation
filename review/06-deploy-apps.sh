#!/usr/bin/env bash
# Step 6 - deploy the platform apps (everything under the environment except s2ap/apps), one namespace at a
# time, in the same alphabetical order and with the same special cases as s2ctl.sh:
#   mongodb, external-secrets  -> server-side apply
#   apisix, cert-manager       -> CRDs first, then everything
#   s2-system                  -> waits for job/openbao-init
# Usage: 06-deploy-apps.sh [--list] [--only APP] [--from APP] [--timeout SECONDS]
for _lib in "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh" "$(dirname "${BASH_SOURCE[0]}")/common.sh"; do
  # shellcheck source=lib/common.sh
  [[ -f $_lib ]] && { source "$_lib"; break; }
done
[[ $(type -t die 2>/dev/null) == function ]] || { echo "ERROR: common.sh not found (expected in lib/ next to this script, or next to it)" >&2; exit 1; }
load_config
require_specs
require_cmd kubectl kustomize helm yq jq
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT

only=''; from=''; list=0; TIMEOUT=300
while [[ $# -gt 0 ]]; do
  case $1 in
    --only) only=$2; shift 2 ;;
    --from) from=$2; shift 2 ;;
    --list) list=1; shift ;;
    --timeout) TIMEOUT=$2; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

apps=()
while IFS= read -r a; do [[ $a == s2ap || $a == apps ]] || apps+=("$a"); done < <(list_apps)
(( ${#apps[@]} )) || die "no apps found under $ENV_DIR"
if (( list )); then printf '%s\n' "${apps[@]}"; exit 0; fi
if [[ -n $only ]]; then
  printf '%s\n' "${apps[@]}" | grep -qx "$only" || die "unknown app '$only' (try --list)"
  apps=("$only")
fi
if [[ -n $from ]]; then
  printf '%s\n' "${apps[@]}" | grep -qx "$from" || die "unknown app '$from' (try --list)"
  while [[ ${apps[0]} != "$from" ]]; do apps=("${apps[@]:1}"); done
fi

apply_crds_first() {   # apply_crds_first RENDERED_FILE
  local crds="$TMPD/crds.yaml"
  yq 'select(.kind == "CustomResourceDefinition")' "$1" > "$crds"
  if [[ -s $crds ]]; then kubectl apply -f "$crds" >/dev/null; sleep 5; fi
  kubectl apply -f "$1"
}

deploy_apisix() {   # deploy_apisix NAMESPACE RENDERED_FILE
  local ns=$1 rendered=$2 desired deployed=apisix-ingress-controller-v2 annotations
  desired=$(yq 'select(.metadata.name == "apisix" and (.kind == "Deployment" or .kind == "DaemonSet")) | .metadata.annotations."selector.ai/ingress"' "$rendered" | head -n1)
  if [[ $(kubectl -n "$ns" get deployments --no-headers 2>/dev/null | wc -l) -gt 0 ]]; then
    annotations=$(kubectl -n "$ns" get pods -o jsonpath='{range .items[*]}{.metadata.annotations.selector\.ai/ingress}{"\n"}{end}')
    if printf '%s\n' "$annotations" | grep -qv '^apisix-ingress-controller-v2$'; then deployed=apisix-ingress-controller-v1; fi
    if [[ $deployed != "$desired" ]]; then
      die "APISIX $deployed is already installed but the specs contain $desired. The v1->v2 migration deletes the old CRDs and deployments; that is deliberately not part of the install scripts. Run the vendor's: s2ctl.sh upgrade apisix"
    fi
  fi
  apply_crds_first "$rendered"
}

wait_job() {   # wait_job NAMESPACE JOB TIMEOUT_SECONDS (no-op when the job does not exist)
  kubectl -n "$1" get job "$2" >/dev/null 2>&1 || return 0
  info "waiting for job/$2 in $1 (up to $3 s)"
  kubectl -n "$1" wait --for=condition=complete "job/$2" --timeout="$3s" \
    || die "job/$2 in $1 did not complete; inspect: kubectl -n $1 logs job/$2"
}

deploy_app() {
  local app=$1 ns dir rendered
  dir="$ENV_DIR/$app"; ns=$(app_namespace "$app"); rendered="$TMPD/$app.yaml"
  [[ -n $ns ]] || die "$app/kustomization.yaml has no namespace"
  log "Step 6: $app -> namespace $ns"
  ensure_pull_secret "$ns"
  kctl -n "$ns" delete jobs --all >/dev/null      # vendor behaviour: jobs re-run on every deploy
  kbuild "$dir" > "$rendered"
  info "rendered $(grep -c '^kind:' "$rendered") objects"
  case $app in
    mongodb|external-secrets) kubectl apply --server-side --force-conflicts -f "$rendered" ;;
    apisix)                   deploy_apisix "$ns" "$rendered" ;;
    cert-manager)             apply_crds_first "$rendered" ;;
    s2-system)                kubectl apply -f "$rendered"; wait_job "$ns" openbao-init 1200 ;;
    *)                        kubectl apply -f "$rendered" ;;
  esac
  if wait_ns_ready "$ns" "$TIMEOUT"; then
    info "$ns is ready"
  else
    warn "$ns still has pods not ready after ${TIMEOUT}s; continuing (s2ctl.sh does the same). Check: kubectl get pods -n $ns"
  fi
}

log "Step 6: platform apps"
assert_context
info "deploy order: ${apps[*]}"
confirm "Deploy ${#apps[@]} app(s) to $(current_context)?" || die "aborted"
for app in "${apps[@]}"; do deploy_app "$app"; done

log "Step 6: done"
next "./07-deploy-s2ap.sh"
