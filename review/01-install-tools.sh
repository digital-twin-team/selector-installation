#!/usr/bin/env bash
# Step 1 - install the toolset on Ubuntu/Debian: apt packages, gcloud CLI, Docker, and the pinned
# kubectl/kind/kustomize/helm/spruce/yaml2json/yq binaries from versions.env.
#
# Best-effort: each tool is installed in its own section with timeouts. A tool whose download host is blocked,
# or whose install fails, is skipped and the script moves on to the next one. The end prints a summary of what is
# installed, what is not (and why) and which hosts could not be reached, and writes the same summary to
# ~/.s2ctl/install-report.txt. Exit status is 1 when anything is missing, so install-all.sh stops here.
#
# Usage: 01-install-tools.sh [--binaries-only]
#   env: S2_SKIP_GCLOUD=Y   don't install gcloud (step 3 then needs a local specs tarball, see README)
#        S2_PROBE_SKIP=Y    try every download even if the reachability probe says the host is blocked
for _lib in "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh" "$(dirname "${BASH_SOURCE[0]}")/common.sh"; do
  # shellcheck source=lib/common.sh
  [[ -f $_lib ]] && { source "$_lib"; break; }
done
[[ $(type -t die 2>/dev/null) == function ]] || { echo "ERROR: common.sh not found (expected in lib/ next to this script, or next to it)" >&2; exit 1; }
load_versions

BINARIES_ONLY=0
while [[ $# -gt 0 ]]; do
  case $1 in
    --binaries-only) BINARIES_ONLY=1; shift ;;
    *) die "unknown argument: $1 (usage: $0 [--binaries-only])" ;;
  esac
done

BIN_DIR="${S2_BIN_DIR:-$(get_kv "$S2CTL_CONFIG" s2_bin_dir 2>/dev/null || echo /usr/local/bin)}"
REMOTE="${S2_REMOTE_INSTALLATION:-$(get_kv "$S2CTL_CONFIG" s2_remote_installation 2>/dev/null || echo N)}"
SKIP_GCLOUD=${S2_SKIP_GCLOUD:-N}
REPORT="$S2CTL_DIR/install-report.txt"
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT

case $(uname -m) in
  x86_64)  ARCH=amd64 ;;
  aarch64) ARCH=arm64; warn "arm64 is untested with the vendor specs" ;;
  *)       die "unsupported architecture: $(uname -m)" ;;
esac
OS_ID=$(get_kv /etc/os-release ID || true)
[[ $OS_ID == ubuntu || $OS_ID == debian ]] || die "this step supports Ubuntu/Debian (got '$OS_ID')"
CODENAME=$(get_kv /etc/os-release UBUNTU_CODENAME || get_kv /etc/os-release VERSION_CODENAME || true)
[[ -n $CODENAME ]] || die "cannot determine the release codename from /etc/os-release"

# ---------------------------------------------------------------- what each tool needs
TOOLS=(apt gcloud docker kubectl kind kustomize helm spruce yaml2json yq)
declare -A TOOL_HOSTS=(
  [gcloud]="packages.cloud.google.com" [docker]="download.docker.com" [kubectl]="dl.k8s.io"
  [kind]="kind.sigs.k8s.io" [helm]="get.helm.sh"
  [kustomize]="github.com objects.githubusercontent.com" [spruce]="github.com objects.githubusercontent.com"
  [yaml2json]="github.com objects.githubusercontent.com" [yq]="github.com objects.githubusercontent.com"
)
declare -A TOOL_WANT=(
  [kubectl]=$KUBECTL_VERSION [kind]=$KIND_VERSION [kustomize]=$KUSTOMIZE_VERSION [helm]=$HELM_VERSION
  [spruce]=$SPRUCE_VERSION [yaml2json]=$YAML2JSON_VERSION [yq]=$YQ_VERSION
)
declare -A WHY=()       # tool -> reason it is not installed
declare -A BLOCKED=()   # host -> 1 when the probe could not reach it

installed_version() {
  case $1 in
    gcloud)    gcloud version 2>/dev/null | head -n1 ;;
    docker)    docker --version 2>/dev/null ;;
    kubectl)   kubectl version --client 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n1 ;;
    kind)      kind version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n1 ;;
    kustomize) kustomize version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n1 ;;
    yq)        yq --version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n1 ;;
    spruce)    spruce --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 ;;
    yaml2json) yaml2json -version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 ;;
    helm)      helm version --template '{{.Version}}' 2>/dev/null ;;
  esac || true
}

# tool_state TOOL -> "skip <reason>" | "ok" (already there) | "todo"
tool_state() {
  case $1 in
    apt)    (( BINARIES_ONLY )) && { echo "skip --binaries-only"; return; }; echo todo ;;
    gcloud) (( BINARIES_ONLY )) && { echo "skip --binaries-only"; return; }
            [[ $SKIP_GCLOUD == Y ]] && { echo "skip S2_SKIP_GCLOUD=Y"; return; }
            command -v gcloud >/dev/null 2>&1 && echo ok || echo todo ;;
    docker) (( BINARIES_ONLY )) && { echo "skip --binaries-only"; return; }
            [[ $REMOTE == Y ]] && { echo "skip remote install"; return; }
            command -v docker >/dev/null 2>&1 && echo ok || echo todo ;;
    kind)   [[ $REMOTE == Y ]] && { echo "skip remote install"; return; }
            [[ $(installed_version kind) == "${TOOL_WANT[kind]}" ]] && echo ok || echo todo ;;
    *)      [[ $(installed_version "$1") == "${TOOL_WANT[$1]}" ]] && echo ok || echo todo ;;
  esac
}

# ---------------------------------------------------------------- sections (each runs in a subshell; a failure
# inside only aborts that section)
install_bin() { "${SUDO[@]}" install -o root -g root -m 0755 "$1" "$BIN_DIR/$2"; info "installed $BIN_DIR/$2"; }

section_apt() {
  # a previous failed run may have left half-written repo files behind; drop the ones this step recreates
  command -v gcloud >/dev/null 2>&1 || "${SUDO[@]}" rm -f /etc/apt/sources.list.d/google-cloud-sdk.list
  command -v docker >/dev/null 2>&1 || "${SUDO[@]}" rm -f /etc/apt/sources.list.d/docker.list
  "${SUDO[@]}" timeout 300 apt-get update -q
  "${SUDO[@]}" timeout 900 apt-get install -y -q apt-transport-https ca-certificates gnupg sed tar gawk jq curl lsb-release git coreutils
}

section_gcloud() {
  fetch https://packages.cloud.google.com/apt/doc/apt-key.gpg "$TMPD/gcloud.gpg"
  "${SUDO[@]}" gpg --dearmor --yes -o /usr/share/keyrings/cloud.google.gpg "$TMPD/gcloud.gpg"
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    | "${SUDO[@]}" tee /etc/apt/sources.list.d/google-cloud-sdk.list >/dev/null
  "${SUDO[@]}" timeout 300 apt-get update -q
  "${SUDO[@]}" timeout 900 apt-get install -y -q google-cloud-cli
}

section_docker() {
  "${SUDO[@]}" install -d -m 0755 /etc/apt/keyrings
  fetch "https://download.docker.com/linux/$OS_ID/gpg" "$TMPD/docker.asc"
  "${SUDO[@]}" install -m 0644 "$TMPD/docker.asc" /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$OS_ID $CODENAME stable" \
    | "${SUDO[@]}" tee /etc/apt/sources.list.d/docker.list >/dev/null
  "${SUDO[@]}" timeout 300 apt-get update -q
  "${SUDO[@]}" timeout 900 apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  "${SUDO[@]}" usermod -aG docker "$(id -un)"
}

section_kubectl() {
  local url="https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/$ARCH/kubectl"
  fetch "$url" "$TMPD/kubectl"; fetch "$url.sha256" "$TMPD/kubectl.sha256"
  verify_sha256 "$TMPD/kubectl" "$(first_sha256_in "$TMPD/kubectl.sha256")" kubectl
  install_bin "$TMPD/kubectl" kubectl
}

section_kind() {
  local url="https://kind.sigs.k8s.io/dl/$KIND_VERSION/kind-linux-$ARCH"
  fetch "$url" "$TMPD/kind"; fetch "$url.sha256sum" "$TMPD/kind.sha256sum"
  verify_sha256 "$TMPD/kind" "$(first_sha256_in "$TMPD/kind.sha256sum")" kind
  install_bin "$TMPD/kind" kind
}

section_kustomize() {
  local base="https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize/$KUSTOMIZE_VERSION"
  local f="kustomize_${KUSTOMIZE_VERSION}_linux_${ARCH}.tar.gz"
  fetch "$base/$f" "$TMPD/$f"; fetch "$base/checksums.txt" "$TMPD/kustomize.checksums"
  verify_sha256 "$TMPD/$f" "$(awk -v f="$f" '$2 == f { print $1 }' "$TMPD/kustomize.checksums")" kustomize
  tar -xzf "$TMPD/$f" -C "$TMPD" kustomize
  install_bin "$TMPD/kustomize" kustomize
}

section_helm() {
  local f="helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
  fetch "https://get.helm.sh/$f" "$TMPD/$f"; fetch "https://get.helm.sh/$f.sha256sum" "$TMPD/helm.sha256sum"
  verify_sha256 "$TMPD/$f" "$(first_sha256_in "$TMPD/helm.sha256sum")" helm
  tar -xzf "$TMPD/$f" -C "$TMPD" "linux-$ARCH/helm"
  install_bin "$TMPD/linux-$ARCH/helm" helm
}

section_spruce() {
  fetch "https://github.com/geofffranks/spruce/releases/download/v$SPRUCE_VERSION/spruce-linux-$ARCH" "$TMPD/spruce"
  verify_sha256 "$TMPD/spruce" "$SPRUCE_SHA256" spruce
  install_bin "$TMPD/spruce" spruce
}

section_yaml2json() {
  fetch "https://github.com/wakeful/yaml2json/releases/download/$YAML2JSON_VERSION/yaml2json-linux-$ARCH" "$TMPD/yaml2json"
  verify_sha256 "$TMPD/yaml2json" "$YAML2JSON_SHA256" yaml2json
  install_bin "$TMPD/yaml2json" yaml2json
}

section_yq() {
  fetch "https://github.com/mikefarah/yq/releases/download/$YQ_VERSION/yq_linux_$ARCH" "$TMPD/yq"
  verify_sha256 "$TMPD/yq" "$YQ_SHA256" yq
  install_bin "$TMPD/yq" yq
}

# ---------------------------------------------------------------- probe the hosts this run needs (in parallel)
declare -A STATE=()
for t in "${TOOLS[@]}"; do STATE[$t]=$(tool_state "$t"); done

hosts=()
for t in "${TOOLS[@]}"; do
  [[ ${STATE[$t]} == todo ]] || continue
  for h in ${TOOL_HOSTS[$t]:-}; do
    printf '%s\n' "${hosts[@]:-}" | grep -qx "$h" || hosts+=("$h")
  done
done
if (( ${#hosts[@]} )); then
  log "Step 1: probing ${#hosts[@]} download host(s), 10 s each, in parallel"
  for h in "${hosts[@]}"; do ( reachable "$h" && touch "$TMPD/$h.ok" ) & done
  wait
  for h in "${hosts[@]}"; do
    if [[ -f $TMPD/$h.ok ]]; then info "ok      $h"; else info "BLOCKED $h"; BLOCKED[$h]=1; fi
  done
fi

# ---------------------------------------------------------------- run the sections, never stopping on one
run_section() {   # run_section TOOL
  local tool=$1 h
  case ${STATE[$tool]} in
    skip*) info "$tool: skipped (${STATE[$tool]#skip })"; return 0 ;;
    ok)    info "$tool: already installed ($(installed_version "$tool"))"; return 0 ;;
  esac
  for h in ${TOOL_HOSTS[$tool]:-}; do
    if [[ -n ${BLOCKED[$h]:-} && ${S2_PROBE_SKIP:-N} != Y ]]; then
      WHY[$tool]="$h unreachable"; warn "$tool: $h is blocked -> skipped, moving on"; return 0
    fi
  done
  if ( "section_$tool" ); then
    info "$tool: done"
  else
    WHY[$tool]="install failed or timed out (see the messages above)"; warn "$tool: failed -> moving on"
  fi
}

had_docker=$(command -v docker 2>/dev/null || true)
for t in "${TOOLS[@]}"; do
  log "Step 1: $t"
  run_section "$t"
done

if [[ -z $had_docker ]] && command -v docker >/dev/null 2>&1; then DOCKER_GROUP_ADDED=1; else DOCKER_GROUP_ADDED=0; fi
proxy_https=${https_proxy:-${HTTPS_PROXY:-}}
if (( ! BINARIES_ONLY )) && [[ -n $proxy_https && $REMOTE != Y ]] && command -v docker >/dev/null 2>&1; then
  "${SUDO[@]}" install -d -m 0755 /etc/systemd/system/docker.service.d
  printf '[Service]\nEnvironment="HTTPS_PROXY=%s"\nEnvironment="HTTP_PROXY=%s"\nEnvironment="NO_PROXY=%s"\n' \
    "$proxy_https" "${http_proxy:-${HTTP_PROXY:-$proxy_https}}" "${no_proxy:-${NO_PROXY:-localhost,127.0.0.1}}" \
    | "${SUDO[@]}" tee /etc/systemd/system/docker.service.d/http-proxy.conf >/dev/null
  "${SUDO[@]}" systemctl daemon-reload && "${SUDO[@]}" systemctl restart docker || warn "could not restart docker with the proxy drop-in"
fi

# ---------------------------------------------------------------- summary (screen + ~/.s2ctl/install-report.txt)
summary() {
  local t v state
  printf 'Step 1 summary  %s  host %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(hostname)"
  printf '%-10s %s\n' TOOL STATUS
  for t in "${TOOLS[@]}"; do
    [[ $t == apt ]] && continue
    state=${STATE[$t]}
    if [[ $state == skip* ]]; then
      printf '%-10s skipped (%s)\n' "$t" "${state#skip }"
    elif [[ -n ${WHY[$t]:-} ]]; then
      v=$(installed_version "$t")
      if [[ -n $v ]]; then printf '%-10s WRONG VERSION (have %s, want %s) - %s\n' "$t" "$v" "${TOOL_WANT[$t]:-?}" "${WHY[$t]}"
      else printf '%-10s NOT INSTALLED - %s\n' "$t" "${WHY[$t]}"; fi
    else
      v=$(installed_version "$t")
      if [[ -n $v ]]; then printf '%-10s installed  %s\n' "$t" "$v"; else printf '%-10s NOT INSTALLED - unknown reason\n' "$t"; fi
    fi
  done
  [[ -n ${WHY[apt]:-} ]] && printf '\napt packages: %s\n' "${WHY[apt]}"
  if (( ${#BLOCKED[@]} )); then
    printf '\nUNREACHABLE HOSTS (open on 443, or fill in proxy.env):\n'
    for h in "${!BLOCKED[@]}"; do printf '  - %s\n' "$h"; done
  else
    printf '\nAll probed hosts were reachable.\n'
  fi
  (( DOCKER_GROUP_ADDED )) && printf '\nDocker was installed and you were added to the docker group: log out and back in before step 4.\n'
  return 0
}

log "Step 1: summary"
summary | tee "$TMPD/summary.txt"
install -d -m 0700 "$S2CTL_DIR" && install -m 0600 "$TMPD/summary.txt" "$REPORT" && info "(saved to $REPORT)"

if (( ${#WHY[@]} )); then
  warn "${#WHY[@]} item(s) missing; fix the network (or versions.env) and re-run this step. Already-installed tools are skipped."
  exit 1
fi
next "./02-configure.sh"
