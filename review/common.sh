#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables here are consumed by the step scripts that source this file
# lib/common.sh - shared helpers for the split s2 installer. Sourced by every step, never executed.
#
# Rules that differ from the vendor's s2ctl.sh:
#   - no `eval`, and no `source` of downloaded or generated files; config files are parsed as KEY=VALUE
#   - credentials never appear on a command line; files that hold them are created 0600
#   - every step that touches Kubernetes asserts the kube context first
#   - a dedicated kubeconfig lives at ~/.s2ctl/kubeconfig (the same path s2ctl.sh uses, so `s2ctl.sh upgrade`
#     keeps working after this installer has run)

set -Eeuo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ${_here##*/} == lib ]]; then S2_SCRIPTS_DIR="${_here%/*}"; else S2_SCRIPTS_DIR="$_here"; fi   # lib/ or flat layout
unset _here
S2CTL_CONFIG="${S2CTL_CONFIG:-$HOME/.s2ctl/config}"
S2CTL_DIR="$(dirname "$S2CTL_CONFIG")"
export KUBECONFIG="$S2CTL_DIR/kubeconfig"
export CLOUDSDK_CORE_DISABLE_USAGE_REPORTING=true CLOUDSDK_COMPONENT_MANAGER_DISABLE_UPDATE_CHECK=true

DOCKER_REGISTRY="us-central1-docker.pkg.dev"
SPECS_BUCKET_PREFIX="s2-deployment"
KUSTOMIZE_BUILD=(build --enable-alpha-plugins --enable-exec --enable-helm)
# Keys written to $S2CTL_CONFIG. The first nine are the vendor's; the rest are additions of this installer.
CONFIG_KEYS=(s2_gcp_key s2_gpg_key s2_deploy_dir s2_deployment_name s2_remote_installation s2_name s2_instance
             s2_bin_dir s2_fqdn s2_kube_context s2_kind_cluster_name s2_store_mode s2_log_path s2_stores_path
             s2_coredns_config)

if [[ -n ${SUDO_USER:-} ]]; then
  printf 'ERROR: run this as your normal user (%s), not with sudo in front; the steps call sudo themselves where needed.\n' "$SUDO_USER" >&2
  exit 1
fi
PROXY_VARS=(http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY)
if [[ $EUID -eq 0 ]]; then SUDO=(); else SUDO=(sudo --preserve-env="$(IFS=,; echo "${PROXY_VARS[*]}")"); fi
if [[ -t 1 ]]; then BOLD=$'\e[1m' RED=$'\e[31m' YELLOW=$'\e[33m' NC=$'\e[0m'; else BOLD='' RED='' YELLOW='' NC=''; fi

log()  { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$NC"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%sWARNING:%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }
next() { printf '\n%sNext:%s %s\n' "$BOLD" "$NC" "$*"; }

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command not found: $c (run 01-install-tools.sh)"
  done
}

# ---------------------------------------------------------------- KEY=VALUE files (read, never sourced)
_unquote() {
  local v=$1
  if [[ ${#v} -ge 2 && $v == \'*\' ]]; then
    v=${v:1:${#v}-2}; v=${v//\'\\\'\'/\'}
  elif [[ ${#v} -ge 2 && $v == \"*\" ]]; then
    v=${v:1:${#v}-2}
  fi
  printf '%s' "$v"
}

# get_kv FILE KEY  -> prints the value; exit 1 if the key is absent
get_kv() {
  local file=$1 key=$2 line
  [[ -f $file ]] || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ $line == "$key="* ]] || continue
    _unquote "${line#*=}"
    return 0
  done < "$file"
  return 1
}

# set_kv FILE KEY VALUE  -> rewrites an existing KEY= line in place; exit 1 (file untouched) if absent
set_kv() {
  local file=$1 key=$2 value=$3 tmp found=0 line
  tmp=$(mktemp)
  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line == "$key="* ]]; then
      printf '%s=%s\n' "$key" "$value"; found=1
    else
      printf '%s\n' "$line"
    fi
  done < "$file" > "$tmp"
  if (( found )); then cat "$tmp" > "$file"; fi
  rm -f "$tmp"
  (( found ))
}

_squote() { local s=${1//\'/\'\\\'\'}; printf "'%s'" "$s"; }

load_versions() {
  local k v
  for k in KUBECTL_VERSION KIND_VERSION KUSTOMIZE_VERSION SPRUCE_VERSION YAML2JSON_VERSION YQ_VERSION HELM_VERSION \
           SPRUCE_SHA256 YAML2JSON_SHA256 YQ_SHA256; do
    v=$(get_kv "$S2_SCRIPTS_DIR/versions.env" "$k" || true)
    printf -v "$k" '%s' "$v"
  done
  [[ -n $KUBECTL_VERSION && -n $HELM_VERSION ]] || die "versions.env is missing or incomplete"
}

# load_config [--optional]  -> populates S2_* variables from $S2CTL_CONFIG (environment fills gaps, never overrides)
load_config() {
  local k n v
  for k in "${CONFIG_KEYS[@]}"; do n=${k^^}; printf -v "$n" '%s' "${!n:-}"; done
  if [[ ! -f $S2CTL_CONFIG ]]; then
    [[ ${1:-} == --optional ]] && return 0
    die "config not found at $S2CTL_CONFIG (run 02-configure.sh first)"
  fi
  for k in "${CONFIG_KEYS[@]}"; do
    n=${k^^}
    if v=$(get_kv "$S2CTL_CONFIG" "$k"); then printf -v "$n" '%s' "$v"; fi
  done
  [[ ${1:-} == --optional ]] && return 0
  [[ -n $S2_DEPLOY_DIR && -n $S2_DEPLOYMENT_NAME && -n $S2_GCP_KEY ]] || die "$S2CTL_CONFIG is incomplete; re-run 02-configure.sh"
  S2_BIN_DIR=${S2_BIN_DIR:-/usr/local/bin}
  S2_REMOTE_INSTALLATION=${S2_REMOTE_INSTALLATION:-N}
  S2_KIND_CLUSTER_NAME=${S2_KIND_CLUSTER_NAME:-kind}
  S2_KUBE_CONTEXT=${S2_KUBE_CONTEXT:-kind-$S2_KIND_CLUSTER_NAME}
  S2_STORE_MODE=${S2_STORE_MODE:-777}
  KUSTOMIZE_DIR="$S2_DEPLOY_DIR/kustomize"
  ENV_DIR="$KUSTOMIZE_DIR/environments/$S2_DEPLOYMENT_NAME"
  PROPS_FILE="$ENV_DIR/components/config/config.properties"
}

save_config() {
  local tmp k n
  install -d -m 0700 "$S2CTL_DIR"
  tmp=$(mktemp)
  for k in "${CONFIG_KEYS[@]}"; do n=${k^^}; printf '%s=%s\n' "$k" "$(_squote "${!n:-}")"; done > "$tmp"
  install -m 0600 "$tmp" "$S2CTL_CONFIG"
  rm -f "$tmp"
}

require_specs() {
  [[ -d $ENV_DIR ]] || die "deployment specs not found at $ENV_DIR (run 03-download-specs.sh)"
  [[ -f $PROPS_FILE ]] || die "config.properties not found at $PROPS_FILE"
}

# ---------------------------------------------------------------- prompts (no eval)
# ask VAR "prompt" [default]  -> assigns VAR from the terminal, or the default when S2_NONINTERACTIVE=Y
ask() {
  local var=$1 prompt=$2 def=${3:-} ans=''
  if [[ ${S2_NONINTERACTIVE:-N} != Y ]]; then
    if [[ -n $def ]]; then read -r -p "$prompt [$def]: " ans; else read -r -p "$prompt: " ans; fi
  fi
  printf -v "$var" '%s' "${ans:-$def}"
}

# confirm "question"  -> 0 on yes. YES_TO_ALL=Y answers yes unless DESTRUCTIVE=1 is set for the call.
confirm() {
  local ans
  if [[ ${YES_TO_ALL:-N} == Y && ${DESTRUCTIVE:-0} != 1 ]]; then return 0; fi
  read -r -p "$1 [y/N]: " ans
  [[ $ans == [Yy]* ]]
}

# confirm_typed "question" "expected"  -> the operator must type the exact expected string; never auto-answered
confirm_typed() {
  local ans
  read -r -p "$1 (type '$2' to continue): " ans
  [[ $ans == "$2" ]]
}

# ---------------------------------------------------------------- running commands, downloads, probes
# Every failure is recorded as "COMMAND -> reason" in $TMPD/last-fail so the summaries can show it verbatim.
cmd_str() { local s="$*"; s=${s#sudo --preserve-env=* }; printf '%s' "$s"; }

# try CMD... -> runs CMD with live output; on failure records "CMD -> exit N: <last output line>" and returns N
try() {
  local rc=0 log="${TMPD:-/tmp}/cmd.log"
  { "$@" 2>&1 | tee "$log"; rc=${PIPESTATUS[0]}; } || true
  if (( rc )); then
    printf '%s -> exit %s: %s\n' "$(cmd_str "$@")" "$rc" "$(tail -n1 "$log" | cut -c1-140)" > "${TMPD:-/tmp}/last-fail"
    return "$rc"
  fi
}

# fetch URL DEST -> curl with timeouts; on failure records "curl -fsSL URL -> reason" and returns 1
fetch() {
  local url=$1 dest=$2 err
  if ! err=$(curl -fsSL --connect-timeout 15 --max-time 600 --retry 2 --retry-delay 3 --proto '=https' -o "$dest" "$url" 2>&1); then
    err=$(printf '%s\n' "$err" | grep -m1 'curl:' | sed -E 's/^curl: //; s/ after [0-9]+ milliseconds//' | cut -c1-100)
    printf 'curl -fsSL %s -> %s\n' "$url" "${err:-failed}" > "${TMPD:-/tmp}/last-fail"
    warn "download failed: $url -> ${err:-failed}"
    return 1
  fi
}

sha256_of() { sha256sum "$1" | awk '{print $1}'; }
first_sha256_in() { grep -oE '[0-9a-f]{64}' "$1" | head -n1 || true; }   # .sha256, .sha256sum, checksums lines

# verify_sha256 FILE EXPECTED LABEL -> dies on mismatch; with EXPECTED empty prints the hash so it can be pinned
verify_sha256() {
  local file=$1 expected=$2 label=$3 actual
  actual=$(sha256_of "$file")
  if [[ -z $expected ]]; then
    warn "$label: no checksum to verify against; downloaded sha256=$actual (pin it in versions.env)"
    return 0
  fi
  if [[ $actual != "$expected" ]]; then
    printf 'sha256sum %s -> mismatch: expected %s got %s\n' "$(basename "$file")" "$expected" "$actual" > "${TMPD:-/tmp}/last-fail"
    die "$label: sha256 mismatch (expected $expected, got $actual)"
  fi
  info "$label: sha256 verified"
}

PROBE_CMD='curl -sS --max-time 10 https://%s/'
# probe_host HOST -> prints "HTTP <code>" (exit 0) or the curl failure reason (exit 1), 10 s max
probe_host() {
  local code err errf="${TMPD:-/tmp}/probe.$1.err"
  code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' "https://$1/" 2>"$errf" || true)
  if [[ -n $code && $code != 000 ]]; then printf 'HTTP %s' "$code"; return 0; fi
  err=$(head -n1 "$errf" | sed -E 's/^curl: //; s/ after [0-9]+ milliseconds//' | cut -c1-80)
  printf '%s' "${err:-no answer}"
  return 1
}
reachable() { probe_host "$1" >/dev/null; }

# require_reachable HOST... -> dies listing every host that cannot be reached, with the probe command and reason
require_reachable() {
  local h r blocked=()
  for h in "$@"; do
    if ! r=$(probe_host "$h"); then blocked+=("$(printf "$PROBE_CMD" "$h") -> $r"); fi
  done
  (( ${#blocked[@]} == 0 )) && return 0
  printf '%s\n' "${blocked[@]}" >&2
  die "${#blocked[@]} host(s) unreachable (egress is blocked or needs proxy.env; run: bash 99-netdiag.sh)"
}

# ---------------------------------------------------------------- GCP
bucket_name() {   # same derivation as s2ctl.sh: prefix-name-sha256(name), truncated to 63 chars
  local n=$1 h full
  h=$(printf '%s' "$n" | sha256sum | awk '{print $1}')
  full="${SPECS_BUCKET_PREFIX}-${n}-${h}"
  printf '%s' "${full:0:63}"
}

gcloud_configuration() {   # activates the service account in its own gcloud configuration; prints its name
  local name
  name=$(jq -r '.client_email | split("@")[0]' "$S2_GCP_KEY")
  if ! gcloud config configurations describe "$name" >/dev/null 2>&1; then
    gcloud config configurations create "$name" --no-activate >/dev/null
  fi
  gcloud auth activate-service-account --configuration "$name" --key-file="$S2_GCP_KEY" >/dev/null
  printf '%s' "$name"
}

# ---------------------------------------------------------------- Kubernetes
kctl() { local i; for i in 1 2 3 4 5; do if kubectl "$@"; then return 0; fi; sleep 2; done; return 1; }

current_context() { kubectl config current-context 2>/dev/null || true; }

assert_context() {
  local ctx server
  [[ -f $KUBECONFIG ]] || die "no kubeconfig at $KUBECONFIG (run 04-create-kind-cluster.sh, or for remote installs 02-configure.sh)"
  ctx=$(current_context)
  [[ -n $ctx ]] || die "no current context in $KUBECONFIG"
  [[ $ctx == "$S2_KUBE_CONTEXT" ]] || die "current context is '$ctx' but the config expects '$S2_KUBE_CONTEXT'; refusing to touch a different cluster"
  server=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
  info "target cluster: context=$ctx server=$server"
}

list_apps() {   # app directories under the environment, alphabetical (the order s2ctl.sh deploys them)
  local d
  for d in "$ENV_DIR"/*/; do
    d=${d%/}
    [[ -f $d/kustomization.yaml ]] && printf '%s\n' "${d##*/}"
  done | sort
}

app_namespace() { yq -r '.namespace // ""' "$ENV_DIR/$1/kustomization.yaml"; }

kbuild() { kustomize "${KUSTOMIZE_BUILD[@]}" "$1"; }

count_not_ready() {   # pods in a namespace that are neither Completed nor fully ready
  kubectl get pods -n "$1" --no-headers 2>/dev/null \
    | awk '!/Completed/ { split($2, a, "/"); if (a[1] != a[2]) n++ } END { print n + 0 }'
}

# wait_ns_ready NAMESPACE TIMEOUT_SECONDS  -> exit 1 on timeout
wait_ns_ready() {
  local ns=$1 timeout=$2 elapsed=0 n
  while :; do
    n=$(count_not_ready "$ns")
    (( n == 0 )) && return 0
    (( elapsed >= timeout )) && return 1
    info "$ns: $n pod(s) not ready (${elapsed}s/${timeout}s)"
    sleep 10; elapsed=$(( elapsed + 10 ))
  done
}

# ensure_pull_secret NAMESPACE  -> creates/updates s2-regcred from the GCP key via a 0600 temp file (never argv)
# and attaches it to the namespace's default service account
ensure_pull_secret() {
  local ns=$1 tmp email i
  tmp=$(mktemp); chmod 0600 "$tmp"
  email=$(jq -r .client_email "$S2_GCP_KEY")
  jq -n --arg reg "https://$DOCKER_REGISTRY" --arg user _json_key --arg email "$email" --rawfile key "$S2_GCP_KEY" \
    '($key | rtrimstr("\n")) as $pw
     | {auths: {($reg): {username: $user, password: $pw, email: $email, auth: (($user + ":" + $pw) | @base64)}}}' > "$tmp"
  kubectl -n "$ns" create secret generic s2-regcred --type=kubernetes.io/dockerconfigjson \
    --from-file=.dockerconfigjson="$tmp" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  rm -f "$tmp"
  for i in $(seq 1 30); do
    kubectl -n "$ns" get serviceaccount default >/dev/null 2>&1 && break
    sleep 2
  done
  kctl -n "$ns" patch serviceaccount default -p '{"imagePullSecrets":[{"name":"s2-regcred"}]}' >/dev/null
}

# ---------------------------------------------------------------- optional proxy (proxy.env next to the scripts)
# Exported here for curl/gcloud/kind, passed through sudo to apt (see SUDO above); step 1 gives the Docker daemon a
# matching drop-in. Leave the file empty (or absent) when the VM has direct egress.
_pf="$S2_SCRIPTS_DIR/proxy.env"
for _k in http_proxy https_proxy no_proxy; do
  _v=$(get_kv "$_pf" "$_k" || true)
  if [[ -n $_v ]]; then export "$_k=$_v" "${_k^^}=$_v"; fi
done
unset _pf _k _v
